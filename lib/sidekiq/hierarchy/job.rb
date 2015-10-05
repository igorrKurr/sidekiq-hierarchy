module Sidekiq
  module Hierarchy
    class Job
      # Job hash keys
      PARENT_FIELD = 'p'.freeze
      STATUS_FIELD = 's'.freeze

      # Values for STATUS_FIELD
      STATUS_QUEUED = '0'.freeze
      STATUS_RUNNING = '1'.freeze
      STATUS_COMPLETE = '2'.freeze
      STATUS_REQUEUED = '3'.freeze

      ONE_MONTH = 60 * 60 * 24 * 30  # key expiration


      ### Class definition

      attr_accessor :jid

      def initialize(jid)
        self.jid = jid
      end

      class << self
        alias_method :find, :new

        def create(jid)
          new(jid).tap { |job| job.enqueue! }  # initial status: enqueued
        end
      end

      def exists?
        Sidekiq.redis do |conn|
          conn.exists(redis_job_hkey)
        end
      end

      def ==(other_job)
        self.jid == other_job.jid
      end

      # Magic getter backed by redis hash
      def [](key)
        Sidekiq.redis do |conn|
          conn.hget(redis_job_hkey, key)
        end
      end

      # Magic setter backed by redis hash
      def []=(key, value)
        Sidekiq.redis do |conn|
          conn.multi do
            conn.hset(redis_job_hkey, key, value)
            conn.expire(redis_job_hkey, ONE_MONTH)
          end
        end
        value
      end


      ### Tree exploration and manipulation

      def parent
        if parent_jid = self[PARENT_FIELD]
          self.class.find(parent_jid)
        end
      end

      def children
        Sidekiq.redis do |conn|
          conn.lrange(redis_children_lkey, 0, -1).map { |jid| self.class.find(jid) }
        end
      end

      def root?
        parent.nil?
      end

      def leaf?
        children.none?
      end

      # Walks up the workflow tree and returns its root job node
      # Caches on first run, as the root is immutable
      # Warning: recursive!
      def root
        # This could be done in a single Lua script server-side...
        @root ||= (self.root? ? self : self.parent.root)
      end

      # Walks down the workflow tree and returns all its leaf nodes
      # If called on a leaf, returns an array containing only itself
      # Warning: recursive!
      def leaves
        # This could be done in a single Lua script server-side...
        self.leaf? ? [self] : children.flat_map(&:leaves)
      end

      # Draws a new doubly-linked parent-child relationship in redis
      def add_child(child_job)
        Sidekiq.redis do |conn|
          conn.multi do
            # draw child->parent relationship
            conn.hset(child_job.redis_job_hkey, PARENT_FIELD, self.jid)
            conn.expire(child_job.redis_job_hkey, ONE_MONTH)
            # draw parent->child relationship
            conn.rpush(redis_children_lkey, child_job.jid)
            conn.expire(redis_children_lkey, ONE_MONTH)
          end
        end
        true  # will never fail w/o raising an exception
      end

      def workflow
        Sidekiq::Hierarchy::Workflow.new(root.jid)
      end


      ### Status get/set

      # Status update: mark as enqueued (step 1)
      def enqueue!
        self[STATUS_FIELD] = STATUS_QUEUED
      end

      def enqueued?
        self[STATUS_FIELD] == STATUS_QUEUED
      end

      # Status update: mark as running (step 2)
      def run!
        self[STATUS_FIELD] = STATUS_RUNNING
      end

      def running?
        self[STATUS_FIELD] == STATUS_RUNNING
      end

      # Status update: mark as complete (step 3)
      def complete!
        self[STATUS_FIELD] = STATUS_COMPLETE
      end

      def complete?
        self[STATUS_FIELD] == STATUS_COMPLETE
      end

      def requeue!
        self[STATUS_FIELD] = STATUS_REQUEUED
      end

      def requeued?
        self[STATUS_FIELD] == STATUS_REQUEUED
      end


      ### Redis backend

      def redis_job_hkey
        "hierarchy:job:#{jid}"
      end

      def redis_children_lkey
        "#{redis_job_hkey}:children"
      end
    end
  end
end