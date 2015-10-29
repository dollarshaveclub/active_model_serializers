require 'thread_safe'

module ActiveModel
  class Serializer
    extend ActiveSupport::Autoload

    autoload :Configuration
    autoload :ArraySerializer
    autoload :Adapter
    autoload :Lint
    autoload :Associations
    autoload :Fieldset
    autoload :Utils
    include Configuration
    include Associations

    # Matches
    #  "c:/git/emberjs/ember-crm-backend/app/serializers/lead_serializer.rb:1:in `<top (required)>'"
    #  AND
    #  "/c/git/emberjs/ember-crm-backend/app/serializers/lead_serializer.rb:1:in `<top (required)>'"
    #  AS
    #  c/git/emberjs/ember-crm-backend/app/serializers/lead_serializer.rb
    CALLER_FILE = /
      \A       # start of string
      \S+      # one or more non-spaces
      (?=      # stop previous match when
        :\d+     # a colon is followed by one or more digits
        :in      # followed by a colon followed by in
      )
    /x

    class << self
      attr_accessor :_attributes
      attr_accessor :_attributes_keys
      attr_accessor :_cache
      attr_accessor :_fragmented
      attr_accessor :_cache_key
      attr_accessor :_cache_only
      attr_accessor :_cache_except
      attr_accessor :_cache_options
      attr_accessor :_cache_digest
    end

    def self.inherited(base)
      base._attributes = self._attributes.try(:dup) || []
      base._attributes_keys = self._attributes_keys.try(:dup) || {}
      base._cache_digest = digest_caller_file(caller.first)
      super
    end

    def self.attributes(*attrs)
      attrs = attrs.first if attrs.first.class == Array
      @_attributes.concat attrs
      @_attributes.uniq!

      attrs.each do |attr|
        define_method attr do
          object && object.read_attribute_for_serialization(attr)
        end unless method_defined?(attr) || _fragmented.respond_to?(attr)
      end
    end

    def self.attribute(attr, options = {})
      key = options.fetch(:key, attr)
      @_attributes_keys[attr] = { key: key } if key != attr
      @_attributes << key unless @_attributes.include?(key)

      ActiveModelSerializers.silence_warnings do
        define_method key do
          object.read_attribute_for_serialization(attr)
        end unless (key != :id && method_defined?(key)) || _fragmented.respond_to?(attr)
      end
    end

    def self.fragmented(serializer)
      @_fragmented = serializer
    end

    # Enables a serializer to be automatically cached
    def self.cache(options = {})
      @_cache = ActionController::Base.cache_store if Rails.configuration.action_controller.perform_caching
      @_cache_key = options.delete(:key)
      @_cache_only = options.delete(:only)
      @_cache_except = options.delete(:except)
      @_cache_options = (options.empty?) ? nil : options
    end

    def self.serializer_for(resource, options = {})

      if resource.respond_to?(:serializer_class)
        resource.serializer_class
      elsif resource.respond_to?(:to_ary)
        config.array_serializer
      else
        options.fetch(:serializer, get_serializer_for(resource.class, options))
      end

    end

    # @see ActiveModel::Serializer::Adapter.lookup
    def self.adapter
      ActiveModel::Serializer::Adapter.lookup(config.adapter)
    end

    def self.root_name
      name.demodulize.underscore.sub(/_serializer$/, '') if name
    end

    attr_accessor :object, :root, :meta, :meta_key, :scope

    def initialize(object, options = {})
      @object = object
      @options = options
      @root = options[:root]
      @meta = options[:meta]
      @meta_key = options[:meta_key]
      @scope = options[:scope]

      scope_name = options[:scope_name]
      if scope_name && !respond_to?(scope_name)
        self.class.class_eval do
          define_method scope_name, lambda { scope }
        end
      end
    end

    def json_key
      @root || object.class.model_name.to_s.underscore
    end

    def attributes(options = {})
      attributes =
        if options[:fields]
          self.class._attributes & options[:fields]
        else
          self.class._attributes.dup
        end

      attributes.each_with_object({}) do |name, hash|
        unless self.class._fragmented
          hash[name] = send(name)
        else
          hash[name] = self.class._fragmented.public_send(name)
        end
      end
    end

    def self.serializers_cache
      @serializers_cache ||= ThreadSafe::Cache.new
    end

    def self.digest_caller_file(caller_line)
      serializer_file_path = caller_line[CALLER_FILE]
      serializer_file_contents = IO.read(serializer_file_path)
      Digest::MD5.hexdigest(serializer_file_contents)
    end

    attr_reader :options

    def self.get_serializer_for(klass, options = {})

      serializers_cache.fetch_or_store(klass) do

        version = get_options_version(options)
        serializer_class_name = highest_serializer_class_name(klass, version)
        serializer_class = serializer_class_name.safe_constantize

        if serializer_class
          serializer_class
        elsif klass.superclass
          get_serializer_for(klass.superclass)
        end

      end

    end

    def self.get_options_version(options)
      return options[:version] unless options[:version].nil?
      return options[:scope].version if options[:scope].respond_to?(:version)
    end

    def self.highest_serializer_class_name(klass, version = nil)

      split_names = klass.name.split('::')
      split_names.map!{ |v| v == 'Models' ? 'Serializers' : v }

      if  klass && klass.inspect != 'NilClass' && version

        serializers_index = split_names.index('Serializers')

        (version).downto(1).each do |i|

          if serializers_index
            split_names.insert(serializers_index + 1, "V#{i.to_s}")
          else
            split_names.insert(-2, "V#{i.to_s}")
          end

          serializer_class_name = "#{split_names.join('::')}Serializer"
          return serializer_class_name if serializer_class_name.safe_constantize

        end

      end

      "#{split_names.join('::')}Serializer"

    end

  end
end
