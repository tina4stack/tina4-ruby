# frozen_string_literal: true

module Tina4
  # QueryBuilder — Fluent SQL query builder.
  #
  # Usage:
  #   # Standalone
  #   result = Tina4::QueryBuilder.from_table("users", db: db)
  #     .select("id", "name")
  #     .where("active = ?", [1])
  #     .order_by("name ASC")
  #     .limit(10)
  #     .get
  #
  #   # From ORM model
  #   result = User.query
  #     .where("age > ?", [18])
  #     .order_by("name")
  #     .get
  #
  class QueryBuilder
    def initialize(table, db: nil)
      @table = table
      @db = db
      @columns = ["*"]
      @wheres = []
      @params = []
      @joins = []
      @group_by_cols = []
      @havings = []
      @having_params = []
      @order_by_cols = []
      @limit_val = nil
      @offset_val = nil
    end

    # Create a QueryBuilder for a table.
    #
    # @param table_name [String] The database table name.
    # @param db [Object, nil] Optional database connection.
    # @return [QueryBuilder]
    def self.from_table(table_name, db: nil)
      new(table_name, db: db)
    end

    # Set the columns to select.
    #
    # @param columns [Array<String>] Column names.
    # @return [self]
    def select(*columns)
      @columns = columns unless columns.empty?
      self
    end

    # Add a WHERE condition with AND.
    #
    # @param condition [String] SQL condition with ? placeholders.
    # @param params [Array] Parameter values.
    # @return [self]
    def where(condition, params = [])
      @wheres << ["AND", condition]
      @params.concat(params)
      self
    end

    # Add a WHERE condition with OR.
    #
    # @param condition [String] SQL condition with ? placeholders.
    # @param params [Array] Parameter values.
    # @return [self]
    def or_where(condition, params = [])
      @wheres << ["OR", condition]
      @params.concat(params)
      self
    end

    # Add an INNER JOIN.
    #
    # @param table [String] Table to join.
    # @param on_clause [String] Join condition.
    # @return [self]
    def join(table, on_clause)
      @joins << "INNER JOIN #{table} ON #{on_clause}"
      self
    end

    # Add a LEFT JOIN.
    #
    # @param table [String] Table to join.
    # @param on_clause [String] Join condition.
    # @return [self]
    def left_join(table, on_clause)
      @joins << "LEFT JOIN #{table} ON #{on_clause}"
      self
    end

    # Add a GROUP BY column.
    #
    # @param column [String] Column name.
    # @return [self]
    def group_by(column)
      @group_by_cols << column
      self
    end

    # Add a HAVING clause.
    #
    # @param expression [String] HAVING expression with ? placeholders.
    # @param params [Array] Parameter values.
    # @return [self]
    def having(expression, params = [])
      @havings << expression
      @having_params.concat(params)
      self
    end

    # Add an ORDER BY clause.
    #
    # @param expression [String] Column and direction (e.g. "name ASC").
    # @return [self]
    def order_by(expression)
      @order_by_cols << expression
      self
    end

    # Set LIMIT and optional OFFSET.
    #
    # @param count [Integer] Maximum rows to return.
    # @param offset [Integer, nil] Number of rows to skip.
    # @return [self]
    def limit(count, offset = nil)
      @limit_val = count
      @offset_val = offset unless offset.nil?
      self
    end

    # Build and return the SQL string without executing.
    #
    # @return [String] The constructed SQL query.
    def to_sql
      sql = "SELECT #{@columns.join(', ')} FROM #{@table}"

      sql += " #{@joins.join(' ')}" unless @joins.empty?

      sql += " WHERE #{build_where}" unless @wheres.empty?

      sql += " GROUP BY #{@group_by_cols.join(', ')}" unless @group_by_cols.empty?

      sql += " HAVING #{@havings.join(' AND ')}" unless @havings.empty?

      sql += " ORDER BY #{@order_by_cols.join(', ')}" unless @order_by_cols.empty?

      sql
    end

    # Execute the query and return the database result.
    #
    # @return [Object] The result from db.fetch.
    def get
      ensure_db!
      sql = to_sql
      all_params = @params + @having_params

      @db.fetch(
        sql,
        all_params.empty? ? [] : all_params,
        limit: @limit_val || 100,
        offset: @offset_val || 0
      )
    end

    # Execute the query and return a single row.
    #
    # @return [Hash, nil] A single row hash, or nil.
    def first
      ensure_db!
      sql = to_sql
      all_params = @params + @having_params

      @db.fetch_one(sql, all_params.empty? ? [] : all_params)
    end

    # Execute the query and return the row count.
    #
    # @return [Integer] Number of matching rows.
    def count
      ensure_db!

      # Build a count query by replacing columns
      original = @columns
      @columns = ["COUNT(*) as cnt"]
      sql = to_sql
      @columns = original

      all_params = @params + @having_params

      row = @db.fetch_one(sql, all_params.empty? ? [] : all_params)
      return 0 if row.nil?

      # Handle case-insensitive column names
      (row["cnt"] || row["CNT"] || row[:cnt] || row[:CNT] || 0).to_i
    end

    # Check whether any matching rows exist.
    #
    # @return [Boolean]
    def exists?
      count > 0
    end

    # Convert the fluent builder state into a MongoDB-compatible query hash.
    #
    # @return [Hash] with keys :filter, :projection, :sort, :limit, :skip (only non-empty).
    def to_mongo
      result = {}

      # -- projection --
      if @columns != ["*"]
        result[:projection] = @columns.each_with_object({}) { |col, h| h[col.strip] = 1 }
      end

      # -- filter --
      unless @wheres.empty?
        param_index = 0
        and_conditions = []
        or_conditions = []

        @wheres.each_with_index do |(connector, condition), i|
          mongo_cond, param_index = parse_condition_to_mongo(condition, param_index)
          if i == 0 || connector == "AND"
            and_conditions << mongo_cond
          else
            or_conditions << mongo_cond
          end
        end

        if or_conditions.any?
          and_merged = merge_mongo_conditions(and_conditions)
          all_branches = [and_merged] + or_conditions
          result[:filter] = { "$or" => all_branches }
        else
          result[:filter] = merge_mongo_conditions(and_conditions)
        end
      end

      # -- sort --
      unless @order_by_cols.empty?
        sort = {}
        @order_by_cols.each do |expr|
          parts = expr.strip.split(/\s+/)
          field = parts[0]
          direction = (parts[1] && parts[1].upcase == "DESC") ? -1 : 1
          sort[field] = direction
        end
        result[:sort] = sort
      end

      # -- limit / skip --
      result[:limit] = @limit_val unless @limit_val.nil?
      result[:skip] = @offset_val unless @offset_val.nil?

      result
    end

    private

    # Parse a single SQL condition into a MongoDB filter hash.
    #
    # @return [Array(Hash, Integer)] [mongo_condition, updated_param_index]
    def parse_condition_to_mongo(condition, param_index)
      cond = condition.strip

      # IS NOT NULL
      if cond.match?(/\A(\w+)\s+IS\s+NOT\s+NULL\z/i)
        field = cond.match(/\A(\w+)/)[1]
        return [{ field => { "$exists" => true, "$ne" => nil } }, param_index]
      end

      # IS NULL
      if cond.match?(/\A(\w+)\s+IS\s+NULL\z/i)
        field = cond.match(/\A(\w+)/)[1]
        return [{ field => { "$exists" => false } }, param_index]
      end

      # NOT IN
      if (m = cond.match(/\A(\w+)\s+NOT\s+IN\s*\(\s*\?\s*\)\z/i))
        val = @params[param_index]
        values = val.is_a?(Array) ? val : [val]
        return [{ m[1] => { "$nin" => values } }, param_index + 1]
      end

      # IN
      if (m = cond.match(/\A(\w+)\s+IN\s*\(\s*\?\s*\)\z/i))
        val = @params[param_index]
        values = val.is_a?(Array) ? val : [val]
        return [{ m[1] => { "$in" => values } }, param_index + 1]
      end

      # LIKE
      if (m = cond.match(/\A(\w+)\s+LIKE\s+\?\z/i))
        val = (@params[param_index] || "").to_s
        pattern = val.gsub("%", ".*").gsub("_", ".")
        return [{ m[1] => { "$regex" => pattern, "$options" => "i" } }, param_index + 1]
      end

      # Comparison operators: >=, <=, <>, !=, >, <, =
      if (m = cond.match(/\A(\w+)\s*(>=|<=|<>|!=|>|<|=)\s*\?\z/))
        field = m[1]
        op = m[2]
        val = @params[param_index]

        op_map = {
          "=" => nil, "!=" => "$ne", "<>" => "$ne",
          ">" => "$gt", ">=" => "$gte",
          "<" => "$lt", "<=" => "$lte"
        }

        mongo_op = op_map[op]
        if mongo_op.nil?
          return [{ field => val }, param_index + 1]
        end
        return [{ field => { mongo_op => val } }, param_index + 1]
      end

      # Fallback
      [{ "$where" => cond }, param_index]
    end

    # Merge multiple single-field mongo condition hashes into one.
    # Uses $and if field keys conflict.
    def merge_mongo_conditions(conditions)
      return conditions[0] if conditions.size == 1

      merged = {}
      has_conflict = false

      conditions.each do |cond|
        cond.each do |key, val|
          if merged.key?(key)
            has_conflict = true
            break
          end
          merged[key] = val
        end
        break if has_conflict
      end

      return { "$and" => conditions } if has_conflict

      merged
    end

    # Build the WHERE clause from accumulated conditions.
    def build_where
      parts = []
      @wheres.each_with_index do |(connector, condition), index|
        if index == 0
          parts << condition
        else
          parts << "#{connector} #{condition}"
        end
      end
      parts.join(" ")
    end

    # Ensure a database connection is available.
    def ensure_db!
      if @db.nil?
        @db = Tina4.database if defined?(Tina4.database) && Tina4.database
      end

      raise "QueryBuilder: No database connection provided." if @db.nil?

      # Check if the database connection is still open
      if @db.respond_to?(:connected) && !@db.connected
        raise "QueryBuilder: No database connection provided."
      end
    end
  end
end
