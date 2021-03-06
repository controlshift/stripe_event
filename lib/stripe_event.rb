require "active_support/notifications"
require "stripe"
require "stripe_event/engine" if defined?(Rails)

module StripeEvent
  class << self
    attr_accessor :adapter, :backend, :event_retriever, :namespace

    def configure(&block)
      raise ArgumentError, "must provide a block" unless block_given?
      block.arity.zero? ? instance_eval(&block) : yield(self)
    end
    alias :setup :configure

    def instrument(params)
      begin
        event = event_retriever.call(params)
      rescue Stripe::StripeError => e
        raise UnauthorizedError.new(e)
      end

      backend.instrument namespace.call(event[:type]), event
    end

    def subscribe(name, callable = Proc.new)
      backend.subscribe namespace.to_regexp(name), adapter.call(callable)
    end

    def all(callable = Proc.new)
      subscribe nil, callable
    end
  end

  class Namespace < Struct.new(:value, :delimiter)
    def call(name = nil)
      "#{value}#{delimiter}#{name}"
    end

    def to_regexp(name = nil)
      %r{^#{Regexp.escape call(name)}}
    end
  end

  class NotificationAdapter < Struct.new(:subscriber)
    def self.call(callable)
      new(callable)
    end

    def call(*args)
      payload = args.last
      subscriber.call(payload)
    end
  end

  class Error < StandardError; end
  class UnauthorizedError < Error; end

  self.adapter = NotificationAdapter
  self.backend = ActiveSupport::Notifications
  self.event_retriever = lambda do |params| 
    # event verification for deauthorization is the opposite, need to check to make sure we really are unauthorized. 
    if params[:type] == 'account.application.deauthorized'
      begin
        Stripe::Event.retrieve(params[:id])
        raise Stripe::StripeError 'account.application.deauthorized Should have been unauthorized.'
      rescue Stripe::StripeError => e
        return params
      end
    else
      Stripe::Event.retrieve(params[:id])
    end 
  end
  self.namespace = Namespace.new("stripe_event", ".")
end
