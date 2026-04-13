# frozen_string_literal: false

require "json"

module Tina4
  # Lightweight, zero-dependency GraphQL implementation for Tina4 Ruby.
  # Mirrors the tina4php-graphql approach: custom recursive-descent parser,
  # depth-first executor, programmatic schema, and ORM auto-schema generation.

  # ─── Type System ──────────────────────────────────────────────────────

  class GraphQLType
    SCALARS = %w[String Int Float Boolean ID].freeze

    attr_reader :name, :kind, :fields, :description

    # kind: :scalar, :object, :list, :non_null, :input_object, :enum
    def initialize(name, kind = :object, fields: {}, of_type: nil, description: nil)
      @name = name
      @kind = kind.to_sym
      @fields = fields        # { field_name => { type:, args:, resolve:, description: } }
      @of_type = of_type      # wrapped type for list / non_null
      @description = description
    end

    def scalar?
      @kind == :scalar || SCALARS.include?(@name)
    end

    def list?
      @kind == :list
    end

    def non_null?
      @kind == :non_null
    end

    def of_type
      @of_type
    end

    # Parse a type string like "String", "String!", "[String]", "[Int!]!"
    def self.parse(type_str)
      type_str = type_str.to_s.strip
      if type_str.end_with?("!")
        inner = parse(type_str[0..-2])
        new(type_str, :non_null, of_type: inner)
      elsif type_str.start_with?("[") && type_str.end_with?("]")
        inner = parse(type_str[1..-2])
        new(type_str, :list, of_type: inner)
      elsif SCALARS.include?(type_str)
        new(type_str, :scalar)
      else
        new(type_str, :object)
      end
    end
  end

  # ─── Schema ───────────────────────────────────────────────────────────

  class GraphQLSchema
    attr_reader :types, :queries, :mutations

    def initialize
      @types = {}
      @queries = {}      # name => { type:, args:, resolve:, description: }
      @mutations = {}
      register_scalars
    end

    # add_type(name, fields) — parity with PHP/Python/Node
    # add_type(type_object)  — legacy Ruby form (type_object responds to .name)
    def add_type(name_or_type, fields = nil)
      if fields
        # New form: add_type("User", { "id" => "ID", "name" => "String" })
        @types[name_or_type] = fields
      else
        # Legacy form: add_type(GraphQLType.new(...))
        @types[name_or_type.name] = name_or_type
      end
    end

    def get_type(name)
      @types[name]
    end

    # Register a query field.
    # Cross-framework form: add_query(name, args, return_type, resolver)
    # Block form also accepted: add_query(name, args, return_type) { |root, args, ctx| ... }
    def add_query(name, args = {}, return_type = nil, resolver = nil, &block)
      resolve = resolver || block
      @queries[name] = { type: return_type, args: args, resolve: resolve }
    end

    # Register a mutation field.
    # Cross-framework form: add_mutation(name, args, return_type, resolver)
    # Block form also accepted: add_mutation(name, args, return_type) { |root, args, ctx| ... }
    def add_mutation(name, args = {}, return_type = nil, resolver = nil, &block)
      resolve = resolver || block
      @mutations[name] = { type: return_type, args: args, resolve: resolve }
    end

    # ── ORM Auto-Schema ──────────────────────────────────────────────────
    # Generates GraphQL types + CRUD queries/mutations from a Tina4::ORM subclass.
    #
    #   schema.from_orm(User)
    #
    # Creates:
    #   Query:    user(id), users(limit, offset)
    #   Mutation: createUser(input), updateUser(id, input), deleteUser(id)
    def from_orm(klass)
      model_name  = klass.name.split("::").last
      type_name   = model_name
      table_lower = model_name.gsub(/([A-Z])/, '_\1').sub(/\A_/, "").downcase
      plural      = "#{table_lower}s"

      # Build GraphQL object type from ORM field definitions
      gql_fields = {}
      pk_field = nil

      if klass.respond_to?(:field_definitions)
        klass.field_definitions.each do |fname, fdef|
          gql_type = ruby_field_to_gql(fdef[:type] || :string)
          gql_fields[fname.to_s] = { type: gql_type }
          pk_field = fname.to_s if fdef[:primary_key]
        end
      end

      pk_field ||= "id"
      gql_fields[pk_field] ||= { type: "ID" }

      obj_type = GraphQLType.new(type_name, :object, fields: gql_fields)
      add_type(obj_type)

      # Input type for create/update
      input_fields = gql_fields.reject { |k, _| k == pk_field }
      input_type = GraphQLType.new("#{type_name}Input", :input_object, fields: input_fields)
      add_type(input_type)

      # ── Queries ──

      # Single record: user(id: ID!): User
      add_query(table_lower, { pk_field => { type: "ID!" } }, type_name) do |_root, args, _ctx|
        record = klass.find_by_id(args[pk_field])
        record&.to_hash
      end

      # List: users(limit: Int, offset: Int): [User]
      add_query(plural, { "limit" => { type: "Int" }, "offset" => { type: "Int" } }, "[#{type_name}]") do |_root, args, _ctx|
        limit  = args["limit"] || 100
        offset = args["offset"] || 0
        result = klass.all(limit: limit, offset: offset)
        result.respond_to?(:to_array) ? result.to_array : Array(result).map { |r| r.respond_to?(:to_hash) ? r.to_hash : r }
      end

      # ── Mutations ──

      # Create
      add_mutation("create#{model_name}", { "input" => { type: "#{type_name}Input!" } }, type_name) do |_root, args, _ctx|
        record = klass.create(args["input"] || {})
        record.respond_to?(:to_hash) ? record.to_hash : record
      end

      # Update
      add_mutation("update#{model_name}", { pk_field => { type: "ID!" }, "input" => { type: "#{type_name}Input!" } }, type_name) do |_root, args, _ctx|
        record = klass.find_by_id(args[pk_field])
        return nil unless record
        (args["input"] || {}).each { |k, v| record.send(:"#{k}=", v) if record.respond_to?(:"#{k}=") }
        record.save
        record.to_hash
      end

      # Delete
      add_mutation("delete#{model_name}", { pk_field => { type: "ID!" } }, "Boolean") do |_root, args, _ctx|
        record = klass.find_by_id(args[pk_field])
        return false unless record
        record.delete
        true
      end
    end

    private

    def register_scalars
      GraphQLType::SCALARS.each do |s|
        @types[s] = GraphQLType.new(s, :scalar)
      end
    end

    def ruby_field_to_gql(field_type)
      case field_type.to_s.downcase
      when "integer", "int"           then "Int"
      when "float", "double", "decimal", "numeric" then "Float"
      when "boolean", "bool"          then "Boolean"
      when "string", "text", "varchar" then "String"
      when "datetime", "date", "timestamp" then "String"
      when "blob", "binary"           then "String"
      when "json", "jsonb"            then "String"
      else "String"
      end
    end
  end

  # ─── Parser (recursive descent) ──────────────────────────────────────

  class GraphQLParser
    Token = Struct.new(:type, :value, :pos)

    KEYWORDS = %w[query mutation fragment on true false null].freeze

    def initialize(source)
      @source = source
      @tokens = tokenize(source)
      @pos = 0
    end

    def parse
      document = { kind: :document, definitions: [] }
      while current
        skip(:comma)
        break unless current
        document[:definitions] << parse_definition
      end
      document
    end

    private

    # ── Tokenizer ──

    def tokenize(src)
      tokens = []
      i = 0
      while i < src.length
        ch = src[i]

        # Skip whitespace
        if ch =~ /\s/
          i += 1
          next
        end

        # Skip comments
        if ch == "#"
          i += 1 while i < src.length && src[i] != "\n"
          next
        end

        # Punctuation
        if "{}()[]!:=@$,".include?(ch)
          tokens << Token.new(:punct, ch, i)
          i += 1
          next
        end

        # Spread operator
        if ch == "." && src[i + 1] == "." && src[i + 2] == "."
          tokens << Token.new(:spread, "...", i)
          i += 3
          next
        end

        # String
        if ch == '"'
          str, i = read_string(src, i)
          tokens << Token.new(:string, str, i)
          next
        end

        # Number
        if ch =~ /[\d\-]/
          num, i = read_number(src, i)
          tokens << Token.new(:number, num, i)
          next
        end

        # Name / keyword
        if ch =~ /[a-zA-Z_]/
          name = ""
          while i < src.length && src[i] =~ /[a-zA-Z0-9_]/
            name << src[i]
            i += 1
          end
          type = KEYWORDS.include?(name) ? :keyword : :name
          tokens << Token.new(type, name, i - name.length)
          next
        end

        i += 1 # skip unknown
      end
      tokens
    end

    def read_string(src, i)
      i += 1 # skip opening quote
      str = ""
      while i < src.length && src[i] != '"'
        if src[i] == "\\"
          i += 1
          case src[i]
          when "n" then str << "\n"
          when "t" then str << "\t"
          when '"' then str << '"'
          when "\\" then str << "\\"
          else str << src[i].to_s
          end
        else
          str << src[i]
        end
        i += 1
      end
      i += 1 # skip closing quote
      [str, i]
    end

    def read_number(src, i)
      start = i
      i += 1 if src[i] == "-"
      i += 1 while i < src.length && src[i] =~ /[\d.eE+\-]/
      [src[start...i], i]
    end

    # ── Token helpers ──

    def current
      @tokens[@pos]
    end

    def peek(offset = 0)
      @tokens[@pos + offset]
    end

    def advance
      tok = @tokens[@pos]
      @pos += 1
      tok
    end

    def expect(type, value = nil)
      tok = current
      if tok.nil?
        raise GraphQLError, "Unexpected end of query, expected #{type} #{value}"
      end
      if tok.type != type || (value && tok.value != value)
        raise GraphQLError, "Expected #{type} '#{value}' at position #{tok.pos}, got #{tok.type} '#{tok.value}'"
      end
      advance
    end

    def match(type, value = nil)
      tok = current
      return nil unless tok
      return nil unless tok.type == type
      return nil if value && tok.value != value
      advance
    end

    def skip(type, value = nil)
      match(type, value) while current && current.type == type && (value.nil? || current.value == value)
    end

    # ── Parse rules ──

    def parse_definition
      tok = current
      if tok.nil?
        raise GraphQLError, "Unexpected end of input"
      end

      if tok.type == :keyword && tok.value == "fragment"
        return parse_fragment
      end

      if tok.type == :keyword && (tok.value == "query" || tok.value == "mutation")
        return parse_operation
      end

      # Shorthand query (just a selection set)
      if tok.type == :punct && tok.value == "{"
        return { kind: :operation, operation: :query, name: nil, variables: [], selection_set: parse_selection_set }
      end

      raise GraphQLError, "Unexpected token '#{tok.value}' at position #{tok.pos}"
    end

    def parse_operation
      op = advance.value.to_sym  # :query or :mutation
      name = match(:name)&.value

      variables = []
      if current&.value == "("
        variables = parse_variable_definitions
      end

      selection_set = parse_selection_set

      { kind: :operation, operation: op, name: name, variables: variables, selection_set: selection_set }
    end

    def parse_variable_definitions
      expect(:punct, "(")
      vars = []
      until current&.value == ")"
        skip(:comma)
        break if current&.value == ")"
        expect(:punct, "$")
        vname = expect(:name).value
        expect(:punct, ":")
        vtype = parse_type_ref
        default = nil
        if match(:punct, "=")
          default = parse_value
        end
        vars << { name: vname, type: vtype, default: default }
      end
      expect(:punct, ")")
      vars
    end

    def parse_type_ref
      if match(:punct, "[")
        inner = parse_type_ref
        expect(:punct, "]")
        type_str = "[#{inner}]"
      else
        type_str = expect(:name).value
      end
      type_str += "!" if match(:punct, "!")
      type_str
    end

    def parse_selection_set
      expect(:punct, "{")
      selections = []
      until current&.value == "}"
        skip(:comma)
        break if current&.value == "}"

        if current&.type == :spread
          selections << parse_fragment_spread
        else
          selections << parse_field
        end
      end
      expect(:punct, "}")
      selections
    end

    def parse_field
      name_tok = expect(:name)
      field_name = name_tok.value
      alias_name = nil

      # Check for alias: alias: fieldName
      if current&.value == ":"
        advance
        alias_name = field_name
        field_name = expect(:name).value
      end

      arguments = {}
      if current&.value == "("
        arguments = parse_arguments
      end

      selection_set = nil
      if current&.value == "{"
        selection_set = parse_selection_set
      end

      { kind: :field, name: field_name, alias: alias_name, arguments: arguments, selection_set: selection_set }
    end

    def parse_arguments
      expect(:punct, "(")
      args = {}
      until current&.value == ")"
        skip(:comma)
        break if current&.value == ")"
        arg_name = expect(:name).value
        expect(:punct, ":")
        args[arg_name] = parse_value
      end
      expect(:punct, ")")
      args
    end

    def parse_value
      tok = current
      case tok.type
      when :string
        advance
        tok.value
      when :number
        advance
        tok.value.include?(".") ? tok.value.to_f : tok.value.to_i
      when :keyword
        advance
        case tok.value
        when "true"  then true
        when "false" then false
        when "null"  then nil
        else tok.value
        end
      when :name
        # Enum value
        advance
        tok.value
      when :punct
        if tok.value == "["
          parse_list_value
        elsif tok.value == "{"
          parse_object_value
        elsif tok.value == "$"
          advance
          { kind: :variable, name: expect(:name).value }
        else
          raise GraphQLError, "Unexpected '#{tok.value}' in value at position #{tok.pos}"
        end
      else
        raise GraphQLError, "Unexpected token type #{tok.type} at position #{tok.pos}"
      end
    end

    def parse_list_value
      expect(:punct, "[")
      items = []
      until current&.value == "]"
        skip(:comma)
        break if current&.value == "]"
        items << parse_value
      end
      expect(:punct, "]")
      items
    end

    def parse_object_value
      expect(:punct, "{")
      obj = {}
      until current&.value == "}"
        skip(:comma)
        break if current&.value == "}"
        key = expect(:name).value
        expect(:punct, ":")
        obj[key] = parse_value
      end
      expect(:punct, "}")
      obj
    end

    def parse_fragment_spread
      expect(:spread)
      if current&.type == :keyword && current&.value == "on"
        # Inline fragment
        advance
        type_name = expect(:name).value
        selection_set = parse_selection_set
        { kind: :inline_fragment, on: type_name, selection_set: selection_set }
      else
        name = expect(:name).value
        { kind: :fragment_spread, name: name }
      end
    end

    def parse_fragment
      expect(:keyword, "fragment")
      name = expect(:name).value
      expect(:keyword, "on")
      type_name = expect(:name).value
      selection_set = parse_selection_set
      { kind: :fragment, name: name, on: type_name, selection_set: selection_set }
    end
  end

  # ─── Executor ─────────────────────────────────────────────────────────

  class GraphQLExecutor
    def initialize(schema)
      @schema = schema
    end

    def execute(document, variables: {}, context: {}, operation_name: nil)
      # Collect fragments
      fragments = {}
      operations = []

      document[:definitions].each do |defn|
        case defn[:kind]
        when :fragment
          fragments[defn[:name]] = defn
        when :operation
          operations << defn
        end
      end

      # Pick the operation
      operation = if operation_name
                    operations.find { |op| op[:name] == operation_name }
                  elsif operations.length == 1
                    operations.first
                  else
                    raise GraphQLError, "Must provide operation name when multiple operations exist"
                  end

      raise GraphQLError, "Unknown operation: #{operation_name}" unless operation

      # Resolve variables
      resolved_vars = resolve_variables(operation[:variables], variables)

      # Choose root fields
      root_fields = case operation[:operation]
                    when :query    then @schema.queries
                    when :mutation then @schema.mutations
                    else raise GraphQLError, "Unsupported operation: #{operation[:operation]}"
                    end

      # Execute selection set
      data = {}
      errors = []

      operation[:selection_set].each do |selection|
        resolve_selection(selection, root_fields, nil, resolved_vars, context, fragments, data, errors)
      end

      result = { "data" => data }
      result["errors"] = errors unless errors.empty?
      result
    end

    private

    def resolve_selection(selection, fields, parent, variables, context, fragments, data, errors)
      case selection[:kind]
      when :field
        resolve_field(selection, fields, parent, variables, context, fragments, data, errors)
      when :fragment_spread
        frag = fragments[selection[:name]]
        if frag
          frag[:selection_set].each do |sel|
            resolve_selection(sel, fields, parent, variables, context, fragments, data, errors)
          end
        end
      when :inline_fragment
        selection[:selection_set].each do |sel|
          resolve_selection(sel, fields, parent, variables, context, fragments, data, errors)
        end
      end
    end

    def resolve_field(selection, fields, parent, variables, context, fragments, data, errors)
      field_name = selection[:name]
      output_name = selection[:alias] || field_name

      # Check directives (@skip, @include, @auth, @role, @guest)
      return unless check_directives(selection[:directives] || [], variables, context)

      # Resolve arguments (substitute variables)
      args = resolve_args(selection[:arguments], variables)

      field_def = fields[field_name]

      # Input validation
      if field_def && field_def[:args]
        validation_errors = validate_args(args, field_def[:args], field_name)
        if validation_errors.any?
          errors.concat(validation_errors)
          data[output_name] = nil
          return
        end
      end

      begin
        if field_def && field_def[:resolve]
          # Inject sub-selections into context for DataLoader/eager-loading
          ctx = context.merge("__selections" => (selection[:selection_set] || []))
          value = field_def[:resolve].call(parent, args, ctx)
        elsif parent.is_a?(Hash)
          value = parent[field_name] || parent[field_name.to_sym]
        else
          value = nil
        end

        # Recurse into nested selections
        if selection[:selection_set] && value
          if value.is_a?(Array)
            data[output_name] = value.map do |item|
              nested = {}
              sub_fields = item.is_a?(Hash) ? item_fields(item) : {}
              selection[:selection_set].each do |sel|
                resolve_selection(sel, sub_fields, item, variables, context, fragments, nested, errors)
              end
              nested
            end
          elsif value.is_a?(Hash)
            nested = {}
            sub_fields = item_fields(value)
            selection[:selection_set].each do |sel|
              resolve_selection(sel, sub_fields, value, variables, context, fragments, nested, errors)
            end
            data[output_name] = nested
          else
            data[output_name] = value
          end
        else
          data[output_name] = coerce_value(value)
        end
      rescue => e
        errors << { "message" => e.message, "path" => [output_name] }
        data[output_name] = nil
      end
    end

    # Build field resolvers from a hash (for nested object access)
    def item_fields(hash)
      result = {}
      hash.each do |k, _v|
        ks = k.to_s
        result[ks] = { resolve: ->(_p, _a, _c) { hash[k] || hash[k.to_s] || hash[k.to_sym] } }
      end
      result
    end

    # Check directives: @skip, @include, @auth, @role, @guest.
    # Returns true if the field should be included.
    def check_directives(directives, variables, context = {})
      directives.each do |d|
        val = d[:arguments]&.dig("if")
        val = variables[val[:name]] if val.is_a?(Hash) && val[:kind] == :variable

        return false if d[:name] == "skip" && val
        return false if d[:name] == "include" && !val

        # Auth: @auth — requires authenticated user
        return false if d[:name] == "auth" && !context["user"]

        # Auth: @role(role: "admin") — requires specific role
        if d[:name] == "role"
          required = d[:arguments]&.dig("role")
          user = context["user"]
          actual = user.is_a?(Hash) ? (user["role"] || user[:role]) : nil
          actual ||= context["role"]
          return false if required.nil? || actual != required
        end

        # Auth: @guest — only for unauthenticated
        return false if d[:name] == "guest" && context["user"]
      end
      true
    end

    # Validate resolved args against declared types.
    def validate_args(args, arg_configs, field_name)
      errors = []
      arg_configs.each do |arg_name, declared_type|
        value = args[arg_name]
        is_non_null = declared_type.to_s.end_with?("!")
        base_type = declared_type.to_s.gsub(/[!\[\]]/, "").strip

        if is_non_null && (value.nil? || value == "")
          errors << {
            "message" => "Argument '#{arg_name}' on field '#{field_name}' is required (type: #{declared_type})",
            "path" => [field_name]
          }
          next
        end

        next if value.nil?

        if %w[Int Float Boolean String ID].include?(base_type)
          unless coerce_check(value, base_type)
            errors << {
              "message" => "Argument '#{arg_name}' on field '#{field_name}' expected type #{base_type}, got #{value.class}",
              "path" => [field_name]
            }
          end
        end
      end
      errors
    end

    def coerce_check(value, type_name)
      case type_name
      when "String", "ID"
        value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(Symbol)
      when "Int"
        return false if value.is_a?(TrueClass) || value.is_a?(FalseClass)
        value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A-?\d+\z/))
      when "Float"
        return false if value.is_a?(TrueClass) || value.is_a?(FalseClass)
        value.is_a?(Numeric) || (value.is_a?(String) && value.match?(/\A-?\d+(\.\d+)?\z/))
      when "Boolean"
        value.is_a?(TrueClass) || value.is_a?(FalseClass) || [0, 1, "true", "false"].include?(value)
      else
        true
      end
    end

    def resolve_args(args, variables)
      return {} unless args
      resolved = {}
      args.each do |key, val|
        resolved[key] = resolve_value(val, variables)
      end
      resolved
    end

    def resolve_value(val, variables)
      if val.is_a?(Hash) && val[:kind] == :variable
        variables[val[:name]]
      elsif val.is_a?(Hash)
        val.transform_values { |v| resolve_value(v, variables) }
      elsif val.is_a?(Array)
        val.map { |v| resolve_value(v, variables) }
      else
        val
      end
    end

    def resolve_variables(var_defs, provided)
      result = {}
      (var_defs || []).each do |vd|
        name = vd[:name]
        result[name] = provided.key?(name) ? provided[name] : vd[:default]
      end
      # Also include any extra provided variables
      provided.each { |k, v| result[k.to_s] = v unless result.key?(k.to_s) }
      result
    end

    def coerce_value(val)
      case val
      when Time, Date then val.iso8601
      when Symbol then val.to_s
      else val
      end
    end
  end

  # ─── Error class ──────────────────────────────────────────────────────

  class GraphQLError < StandardError; end

  # ─── Main GraphQL class ──────────────────────────────────────────────

  class GraphQL
    attr_reader :schema

    def initialize(schema = nil)
      @schema = schema || GraphQLSchema.new
      @executor = GraphQLExecutor.new(@schema)
    end

    # Execute a query string directly
    def execute(query, variables: {}, context: {}, operation_name: nil)
      parser = GraphQLParser.new(query)
      document = parser.parse
      @executor.execute(document, variables: variables, context: context, operation_name: operation_name)
    rescue GraphQLError => e
      { "data" => nil, "errors" => [{ "message" => e.message }] }
    rescue => e
      { "data" => nil, "errors" => [{ "message" => "Internal error: #{e.message}" }] }
    end

    # Return schema as GraphQL SDL string.
    def schema_sdl
      sdl = ""
      @schema.types.each do |name, type_obj|
        sdl += "type #{name} {\n"
        type_obj.fields.each { |f| sdl += "  #{f[:name]}: #{f[:type]}\n" }
        sdl += "}\n\n"
      end
      unless @schema.queries.empty?
        sdl += "type Query {\n"
        @schema.queries.each do |name, config|
          args = (config[:args] || {}).map { |k, v| "#{k}: #{v}" }.join(", ")
          arg_str = args.empty? ? "" : "(#{args})"
          sdl += "  #{name}#{arg_str}: #{config[:type]}\n"
        end
        sdl += "}\n\n"
      end
      unless @schema.mutations.empty?
        sdl += "type Mutation {\n"
        @schema.mutations.each do |name, config|
          args = (config[:args] || {}).map { |k, v| "#{k}: #{v}" }.join(", ")
          arg_str = args.empty? ? "" : "(#{args})"
          sdl += "  #{name}#{arg_str}: #{config[:type]}\n"
        end
        sdl += "}\n\n"
      end
      sdl
    end

    # Return schema metadata for debugging.
    def introspect
      queries = @schema.queries.transform_values { |v| { type: v[:type], args: v[:args] || {} } }
      mutations = @schema.mutations.transform_values { |v| { type: v[:type], args: v[:args] || {} } }
      { types: @schema.types.keys, queries: queries, mutations: mutations }
    end

    # Handle an HTTP request body (JSON string)
    def handle_request(body, context: {})
      payload = JSON.parse(body)
      query = payload["query"] || ""
      variables = payload["variables"] || {}
      op_name = payload["operationName"]

      execute(query, variables: variables, context: context, operation_name: op_name)
    rescue JSON::ParserError
      { "data" => nil, "errors" => [{ "message" => "Invalid JSON in request body" }] }
    end

    # ── Route Registration ─────────────────────────────────────────────
    # Register a POST /graphql route in the Tina4 router.
    #
    #   gql = Tina4::GraphQL.new(schema)
    #   gql.register_route           # POST /graphql
    #   gql.register_route("/api/graphql")  # custom path
    #
    def register_route(path = "/graphql")
      graphql = self
      Tina4.post path, auth: false do |request, response|
        body = request.body
        result = graphql.handle_request(body, context: { request: request })
        response.json(result)
      end

      # Optional: GET for GraphiQL/introspection
      Tina4.get path, auth: false do |request, response|
        query = request.params["query"]
        if query
          variables = request.params["variables"]
          variables = JSON.parse(variables) if variables.is_a?(String) && !variables.empty?
          result = graphql.execute(query, variables: variables || {}, context: { request: request })
          response.json(result)
        else
          response.html(graphiql_html(path))
        end
      end
    end

    private

    def graphiql_html(endpoint)
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <title>GraphiQL — Tina4 Ruby</title>
          <link rel="stylesheet" href="https://unpkg.com/graphiql@3/graphiql.min.css" />
        </head>
        <body style="margin:0;height:100vh;">
          <div id="graphiql" style="height:100vh;"></div>
          <script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
          <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
          <script crossorigin src="https://unpkg.com/graphiql@3/graphiql.min.js"></script>
          <script>
            const fetcher = GraphiQL.createFetcher({ url: '#{endpoint}' });
            ReactDOM.createRoot(document.getElementById('graphiql'))
              .render(React.createElement(GraphiQL, { fetcher }));
          </script>
        </body>
        </html>
      HTML
    end
  end
end
