require 'active_support/concern'

module Protip

  # Wraps a protobuf message to allow:
  # - getting/setting of certain message fields as if they were more complex Ruby objects
  # - mass assignment of attributes
  # - standardized creation of nested messages that can't be converted to/from Ruby objects
  class Wrapper
    attr_reader :message, :converter
    def initialize(message, converter)
      @message = message
      @converter = converter
    end

    def respond_to?(name)
      if super
        true
      else
        message.class.descriptor.any? do |field|
          # getter, setter, and in the scalar enum case, query method
          regex = /^#{field.name}[=#{self.class.matchable?(field) ? '\\?' : ''}]?$/
          name.to_s =~ regex
        end
      end
    end

    def method_missing(name, *args)
      if (name =~ /=$/ && field = message.class.descriptor.detect{|field| :"#{field.name}=" == name})
        raise ArgumentError unless args.length == 1
        attributes = {}.tap { |hash| hash[field.name] = args[0] }
        assign_attributes attributes
        args[0] # return the input value (to match ActiveRecord behavior)
      elsif (name =~ /\?$/ && field = message.class.descriptor.detect{|field| self.class.matchable?(field) && :"#{field.name}?" == name})
        if args.length == 1
          # this is an enum query, e.g. `state?(:CREATED)`
          matches? field, args[0]
        elsif args.length == 0
          # this is a boolean query, e.g. `approved?`
          get field
        else
          raise ArgumentError
        end
      elsif (field = message.class.descriptor.detect{|field| field.name.to_sym == name})
        raise ArgumentError unless args.length == 0
        get field
      else
        super
      end
    end

    # Create a nested field on our message. For example, given the following definitions:
    #
    #   message Inner {
    #     optional string str = 1;
    #   }
    #   message Outer {
    #     optional Inner inner = 1;
    #   }
    #
    # We could create an inner message using:
    #
    #   wrapper = Protip::Wrapper.new(Outer.new, converter)
    #   wrapper.inner # => nil
    #   wrapper.build(:inner, str: 'example')
    #   wrapper.inner.str # => 'example'
    #
    # Rebuilds the field if it's already present. Raises an error if the name of a primitive field
    # or a convertible message field is given.
    #
    # @param field_name [String|Symbol] The field name to build
    # @param attributes [Hash] The initial attributes to set on the field (as parsed by +assign_attributes+)
    # @return [Protip::Wrapper] The created field
    def build(field_name, attributes = {})

      field = message.class.descriptor.detect{|field| field.name.to_sym == field_name.to_sym}
      if !field
        raise "No field named #{field_name}"
      elsif field.type != :message
        raise "Can only build message fields: #{field_name}"
      elsif converter.convertible?(field.subtype.msgclass)
        raise "Cannot build a convertible field: #{field.name}"
      end

      message[field_name.to_s] = field.subtype.msgclass.new
      wrapper = get(field)
      wrapper.assign_attributes attributes
      wrapper
    end

    # Mass assignment of message attributes. Nested messages will be built if necessary, but not overwritten
    # if they already exist.
    #
    # @param attributes [Hash] The attributes to set. Keys are field names. For primitive fields and message fields
    #   which are convertible to/from Ruby objects, values are the same as you'd pass to the field's setter
    #   method. For nested message fields which can't be converted to/from Ruby objects, values are attribute
    #   hashes which will be passed down to +assign_attributes+ on the nested field.
    # @return [NilClass]
    def assign_attributes(attributes)
      attributes.each do |field_name, value|
        field = message.class.descriptor.detect{|field| field.name == field_name.to_s}
        if !field
          raise ArgumentError.new("Unrecognized field: #{field_name}")
        end

        # For inconvertible nested messages, the value should be either a hash or a message
        if field.type == :message && !converter.convertible?(field.subtype.msgclass)
          if value.is_a?(field.subtype.msgclass) # If a message, set it directly
            set(field, value)
          elsif value.is_a?(Hash) # If a hash, pass it through to the nested message
            wrapper = get(field) || build(field.name) # Create the field if it doesn't already exist
            wrapper.assign_attributes value
          else # If value is a simple type (e.g. nil), set the value directly
            set(field, value)
          end
        # Otherwise, if the field is a convertible message or a simple type, we set the value directly
        else
          set(field, value)
        end
      end

      nil # Return nil to match ActiveRecord behavior
    end

    def as_json
      to_h.as_json
    end

    # @return [Hash] A hash whose keys are the fields of our message, and whose values are the Ruby representations
    #   (either nested hashes or converted messages) of the field values.
    def to_h
      hash = {}
      message.class.descriptor.each do |field|
        value = public_send(field.name)
        if field.label == :repeated
          value.map!{|v| v.is_a?(self.class) ? v.to_h : v}
        else
          value = (value.is_a?(self.class) ? value.to_h : value)
        end
        hash[field.name.to_sym] = value
      end
      hash
    end

    def ==(wrapper)
      wrapper.class == self.class &&
        wrapper.message.class == message.class &&
        message.class.encode(message) == wrapper.message.class.encode(wrapper.message) &&
        converter == wrapper.converter
    end

    class << self
      # Semi-private check for whether a field should have an associated query method (e.g. +field_name?+).
      # @return [Boolean] Whether the field should have an associated query method on wrappers.
      def matchable?(field)
        return false if field.label == :repeated

        field.type == :enum ||
            field.type == :bool ||
            field.type == :message && (field.subtype.name == "google.protobuf.BoolValue")
      end
    end

    private

    def get(field)
      if field.label == :repeated
        message[field.name].map{|value| to_ruby_value field, value}
      else
        to_ruby_value field, message[field.name]
      end
    end

    # Helper for getting values - converts the value for the given field to one that we can return to the user
    def to_ruby_value(field, value)
      if field.type == :message
        if nil == value
          nil
        elsif converter.convertible?(field.subtype.msgclass)
          converter.to_object value
        else
          self.class.new value, converter
        end
      else
        value
      end
    end

    def set(field, value)
      if field.label == :repeated
        message[field.name].replace value.map{|v| to_protobuf_value field, v}
      else
        message[field.name] = to_protobuf_value(field, value)
      end
    end

    # Helper for setting values - converts the value for the given field to one that we can set directly
    def to_protobuf_value(field, value)
      if field.type == :message
        if nil == value
          nil
        elsif value.is_a?(field.subtype.msgclass)
          value
        elsif converter.convertible?(field.subtype.msgclass)
          converter.to_message value, field.subtype.msgclass
        else
          raise ArgumentError.new "Cannot convert from Ruby object: \"#{field}\""
        end
      elsif field.type == :enum
        value.is_a?(Fixnum) ? value : value.to_sym
      else
        value
      end
    end

    def matches?(field, value)
      enum = field.subtype
      if value.is_a?(Fixnum)
        sym = enum.lookup_value(value)
      else
        sym = value.to_sym
        sym = nil if (nil == enum.lookup_name(sym))
      end
      raise RangeError.new("#{field} has no value #{value}") if nil == sym
      get(field) == sym

    end
  end
end