# frozen_string_literal: true

module Tina4
  # Request body validator with chainable rules.
  #
  # Usage:
  #   validator = Tina4::Validator.new(request.body)
  #   validator.required("name", "email")
  #            .email("email")
  #            .min_length("name", 2)
  #            .max_length("name", 100)
  #            .integer("age")
  #            .min("age", 0)
  #            .max("age", 150)
  #            .in_list("role", ["admin", "user", "guest"])
  #            .regex("phone", /^\+?[\d\s\-]+$/)
  #
  #   unless validator.is_valid?
  #     return response.error("VALIDATION_FAILED", validator.errors.first[:message], 400)
  #   end
  #
  class Validator
    attr_reader :validation_errors

    EMAIL_REGEX = /\A[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}\z/

    def initialize(data = {})
      @data = data.is_a?(Hash) ? data : {}
      # Normalise keys to strings for consistent lookup
      @data = @data.transform_keys(&:to_s) unless @data.empty?
      @validation_errors = []
    end

    # Check that one or more fields are present and non-empty.
    def required(*fields)
      fields.each do |field|
        key = field.to_s
        value = @data[key]
        if value.nil? || (value.is_a?(String) && value.strip.empty?)
          @validation_errors << { field: key, message: "#{key} is required" }
        end
      end
      self
    end

    # Check that a field contains a valid email address.
    def email(field)
      key = field.to_s
      value = @data[key]
      return self if value.nil?

      unless value.is_a?(String) && value.match?(EMAIL_REGEX)
        @validation_errors << { field: key, message: "#{key} must be a valid email address" }
      end
      self
    end

    # Check that a string field has at least +length+ characters.
    def min_length(field, length)
      key = field.to_s
      value = @data[key]
      return self if value.nil?

      unless value.is_a?(String) && value.length >= length
        @validation_errors << { field: key, message: "#{key} must be at least #{length} characters" }
      end
      self
    end

    # Check that a string field has at most +length+ characters.
    def max_length(field, length)
      key = field.to_s
      value = @data[key]
      return self if value.nil?

      unless value.is_a?(String) && value.length <= length
        @validation_errors << { field: key, message: "#{key} must be at most #{length} characters" }
      end
      self
    end

    # Check that a field is an integer (or can be parsed as one).
    def integer(field)
      key = field.to_s
      value = @data[key]
      return self if value.nil?

      if value.is_a?(Integer)
        return self
      end

      begin
        Integer(value)
      rescue ArgumentError, TypeError
        @validation_errors << { field: key, message: "#{key} must be an integer" }
      end
      self
    end

    # Check that a numeric field is >= +minimum+.
    def min(field, minimum)
      key = field.to_s
      value = @data[key]
      return self if value.nil?

      begin
        num = Float(value)
      rescue ArgumentError, TypeError
        return self
      end

      if num < minimum
        @validation_errors << { field: key, message: "#{key} must be at least #{minimum}" }
      end
      self
    end

    # Check that a numeric field is <= +maximum+.
    def max(field, maximum)
      key = field.to_s
      value = @data[key]
      return self if value.nil?

      begin
        num = Float(value)
      rescue ArgumentError, TypeError
        return self
      end

      if num > maximum
        @validation_errors << { field: key, message: "#{key} must be at most #{maximum}" }
      end
      self
    end

    # Check that a field's value is one of the allowed values.
    def in_list(field, allowed)
      key = field.to_s
      value = @data[key]
      return self if value.nil?

      unless allowed.include?(value)
        @validation_errors << { field: key, message: "#{key} must be one of #{allowed}" }
      end
      self
    end

    # Check that a field matches a regular expression.
    def regex(field, pattern)
      key = field.to_s
      value = @data[key]
      return self if value.nil?

      regexp = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
      unless value.is_a?(String) && value.match?(regexp)
        @validation_errors << { field: key, message: "#{key} does not match the required format" }
      end
      self
    end

    # Return the list of validation errors (empty if valid).
    def errors
      @validation_errors.dup
    end

    # Return true if no validation errors have been recorded.
    def is_valid?
      @validation_errors.empty?
    end

    # Alias for is_valid? (Ruby convention)
    alias_method :valid?, :is_valid?
  end
end
