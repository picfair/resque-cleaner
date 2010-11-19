require 'time'
module Resque
  module Plugins
    # ResqueCleaner class provides useful functionalities to retry or clean
    # failed jobs. Let's clean up your failed list!
    class ResqueCleaner
      include Resque::Helpers
      # ResqueCleaner fetches all elements from Redis and checks them
      # by linear when filtering them. Since there is a performance concern,
      # ResqueCleaner handles only the latest x(default 1000) jobs.
      #
      # You can change the value through limiter attribute.
      # e.g. cleaner.limiter.maximum = 5000
      attr_reader :limiter

      # Set false if you don't show any message.
      attr_accessor :print_message

      # Initializes instance
      def initialize
        @failure = Resque::Failure.backend
        @print_message = true
        @limiter = Limiter.new self
      end

      # Returns redis instance.
      def redis
        Resque.redis
      end

      # Returns failure backend. Only supports redis backend.
      def failure
        @failure
      end

      # Stats by date.
      def stats_by_date(&block)
        jobs, stats = select(&block), {}
        jobs.each do |job|
          date = job["failed_at"][0,10]
          stats[date] ||= 0
          stats[date] += 1
        end

        print_stats(stats) if print?
        stats 
      end

      # Stats by class.
      def stats_by_class(&block)
        jobs, stats = select(&block), {}
        jobs.each do |job|
          klass = job["payload"]["class"]
          stats[klass] ||= 0
          stats[klass] += 1
        end

        print_stats(stats) if print?
        stats 
      end

      # Print stats
      def print_stats(stats)
        log too_many_message if @limiter.on?
        stats.keys.sort.each do |k|
          log "%15s: %4d" % [k,stats[k]]
        end
        log "%15s: %4d" % ["total", @limiter.count]
      end

      # Returns every jobs for which block evaluates to true.
      def select(&block)
        jobs = @limiter.jobs
        block_given? ? @limiter.jobs.select(&block) : jobs
      end
      alias :failure_jobs :select

      # Clears every jobs for which block evaluates to true.
      def clear(&block)
        cleared = 0
        @limiter.lock do
          @limiter.jobs.each_with_index do |job,i|
            if !block_given? || block.call(job)
              index = @limiter.start_index + i - cleared
              # fetches again since you can't ensure that it is always true:
              # a == endode(decode(a))
              value = redis.lindex(:failed, index)
              redis.lrem(:failed, 1, value)
              cleared += 1
            end
          end
        end
        cleared
      end

      # Retries every jobs for which block evaluates to true.
      def requeue(clear_after_requeue=false, &block)
        requeued = 0
        @limiter.lock do
          @limiter.jobs.each_with_index do |job,i|
            if !block_given? || block.call(job)
              index = @limiter.start_index + i - requeued

              if clear_after_requeue
                # remove job
                value = redis.lindex(:failed, index)
                redis.lrem(:failed, 1, value)
              else
                # mark retried
                job['retried_at'] = Time.now.strftime("%Y/%m/%d %H:%M:%S")
                redis.lset(:failed, @limiter.start_index+i, Resque.encode(job))
              end

              Job.create(job['queue'], job['payload']['class'], *job['payload']['args'])
              requeued += 1
            end
          end
        end
        requeued
      end

      # Clears all jobs except the last X jobs
      def clear_stale
        return 0 unless @limiter.on?
        c = @limiter.maximum
        redis.ltrim(:failed, -c, -1)
        c
      end

      # Exntends job(Hash instance) with some helper methods.
      module FailedJobEx
        # Returns true if the job has been already retried. Otherwise returns
        # false.
        def retried?
          self['retried_at'].blank?
        end
        alias :requeued? :retried?

        # Returns true if the job processed(failed) before the given time.
        # Otherwise returns false.
        # You can pass Time object or String.
        def before?(time)
          time = Time.parse(time) if time.is_a?(String)
          Time.parse(self['failed_at']) < time
        end

        # Returns true if the job processed(failed) after the given time.
        # Otherwise returns false.
        # You can pass Time object or String.
        def after?(time)
          time = Time.parse(time) if time.is_a?(String)
          Time.parse(self['failed_at']) >= time
        end

        # Returns true if the class of the job matches. Otherwise returns false.
        def klass?(klass_or_name)
          self["payload"]["class"] == klass_or_name.to_s
        end

        # Returns true if the queue of the job matches. Otherwise returns false.
        def queue?(queue)
          self["queue"] == queue.to_s
        end
      end

      # Through the Limiter class, you accesses only the last x(default 1000)
      # jobs. 
      class Limiter
        DEFAULT_MAX_JOBS = 1000
        attr_accessor :maximum
        def initialize(cleaner)
          @cleaner = cleaner
          @maximum = DEFAULT_MAX_JOBS
          @locked = false
        end

        # Returns true if limiter is ON: number of failed jobs is more than
        # maximum value.
        def on?
          @cleaner.failure.count > @maximum
        end

        # Returns limited count.
        def count
          if @locked
            @jobs.size
          else
            on? ? @maximum : @cleaner.failure.count
          end
        end

        # Returns jobs. If numbers of jobs is more than maixum, it returns only
        # the maximum.
        def jobs
          if @locked
            @jobs
          else
            all( - count, count)
          end
        end

        # Wraps Resque's all and returns always array.
        def all(index=0,count=1)
          jobs = @cleaner.failure.all( index, count)
          jobs = [] unless jobs
          jobs = [jobs] unless jobs.is_a?(Array)
          jobs.each{|j| j.extend FailedJobEx}
          jobs
        end

        # Returns a start index of jobs in :failed list.
        def start_index
          if @locked
            @start_index
          else
            on? ? @cleaner.failure.count-@maximum : 0
          end
        end

        # Assuming new failures pushed while cleaner is dealing with failures,
        # you need to lock the range.
        def lock
          old = @locked

          unless @locked
            total_count = @cleaner.failure.count
            if total_count>@maximum
              @start_index = total_count-@maximum
              @jobs = all( @start_index, @maximum)
            else
              @start_index = 0
              @jobs = all( 0, total_count)
            end
          end

          @locked = true
          yield
        ensure
          @locked = old
        end
      end

      # Outputs message. Overrides this method when you want to change a output
      # stream.
      def log(msg)
        puts msg if print?
      end

      def print?
        @print_message
      end

      def too_many_message
        "There are too many failed jobs(count=#{@failure.count}). This only looks at last #{@limiter.maximum} jobs."
      end
    end
  end
end


