# frozen_string_literal: true

module Tina4
  # QueryBuilder — Fluent SQL query builder.
  #
  # Usage:
  #   # Standalone
  #   result = Tina4::QueryBuilder.from("users", db: db)
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
    def self.from(table_name, db: nil)
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

    private

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
      return unless @db.nil?

      @db = Tina4.database if defined?(Tina4.database) && Tina4.database
      raise "QueryBuilder: No database connection provided." if @db.nil?
    end
  end
end
