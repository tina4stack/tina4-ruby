# frozen_string_literal: true
require "json"

module Tina4
  class DatabaseResult
    include Enumerable

    attr_reader :records, :columns, :count, :limit, :offset, :sql,
                :affected_rows, :last_id, :error

    def initialize(records = [], sql: "", columns: [], count: nil, limit: 10, offset: 0,
                   affected_rows: 0, last_id: nil, error: nil, db: nil)
      @records = records || []
      @sql = sql
      @columns = columns.empty? && !@records.empty? ? @records.first.keys : columns
      @count = count || @records.length
      @limit = limit
      @offset = offset
      @affected_rows = affected_rows
      @last_id = last_id
      @error = error
      @db = db
      @column_info_cache = nil
    end

    def each(&block)
      @records.each(&block)
    end

    def first
      @records.first
    end

    def last
      @records.last
    end

    def empty?
      @records.empty?
    end

    def [](index)
      @records[index]
    end

    def length
      @count
    end

    def size
      @count
    end

    def success?
      @error.nil?
    end

    def to_array
      @records.map do |record|
        record.is_a?(Hash) ? record : record.to_h
      end
    end

    alias to_a to_array

    def to_json(*_args)
      JSON.generate(to_array)
    end

    def to_csv(separator: ",", headers: true)
      return "" if @records.empty?
      lines = []
      cols = @records.first.keys
      lines << cols.join(separator) if headers
      @records.each do |row|
        lines << cols.map { |c| escape_csv(row[c], separator) }.join(separator)
      end
      lines.join("\n")
    end

    def to_paginate(page: nil, per_page: nil)
      per_page ||= @limit > 0 ? @limit : 10
      page ||= @offset > 0 ? (@offset / per_page) + 1 : 1
      total = @count
      total_pages = [1, (total.to_f / per_page).ceil].max
      slice_offset = (page - 1) * per_page
      page_records = @records[slice_offset, per_page] || []
      {
        data: page_records,
        page: page,
        per_page: per_page,
        total: total,
        total_pages: total_pages,
        has_next: page < total_pages,
        has_prev: page > 1
      }
    end

    def to_crud(table_name: "data", primary_key: "id", editable: true)
      Tina4::Crud.generate_table(@records, table_name: table_name,
                                  primary_key: primary_key, editable: editable)
    end

    # Return column metadata for the query's table.
    #
    # Lazy — only queries the database when explicitly called. Caches the
    # result so subsequent calls return immediately without re-querying.
    #
    # Returns an array of hashes with keys:
    #   name, type, size, decimals, nullable, primary_key
    def column_info
      return @column_info_cache if @column_info_cache

      table = extract_table_from_sql

      if @db && table
        begin
          @column_info_cache = query_column_metadata(table)
          return @column_info_cache
        rescue StandardError
          # Fall through to fallback
        end
      end

      @column_info_cache = fallback_column_info
      @column_info_cache
    end

    private

    def extract_table_from_sql
      return nil if @sql.nil? || @sql.empty?

      if (m = @sql.match(/\bFROM\s+["']?(\w+)["']?/i))
        return m[1]
      end
      if (m = @sql.match(/\bINSERT\s+INTO\s+["']?(\w+)["']?/i))
        return m[1]
      end
      if (m = @sql.match(/\bUPDATE\s+["']?(\w+)["']?/i))
        return m[1]
      end
      nil
    end

    def query_column_metadata(table)
      # Use the database's columns method which delegates to the driver
      raw_cols = @db.columns(table)
      normalize_columns(raw_cols)
    rescue StandardError
      fallback_column_info
    end

    def normalize_columns(raw_cols)
      raw_cols.map do |col|
        col_type = (col[:type] || col["type"] || "UNKNOWN").to_s.upcase
        size, decimals = parse_type_size(col_type)
        {
          name: (col[:name] || col["name"]).to_s,
          type: col_type.sub(/\(.*\)/, ""),
          size: size,
          decimals: decimals,
          nullable: col.key?(:nullable) ? col[:nullable] : (col.key?("nullable") ? col["nullable"] : true),
          primary_key: col[:primary_key] || col["primary_key"] || col[:primary] || col["primary"] || false
        }
      end
    end

    def parse_type_size(type_str)
      if (m = type_str.match(/\((\d+)(?:\s*,\s*(\d+))?\)/))
        size = m[1].to_i
        decimals = m[2] ? m[2].to_i : nil
        [size, decimals]
      else
        [nil, nil]
      end
    end

    def fallback_column_info
      return [] if @records.empty?
      keys = @records.first.is_a?(Hash) ? @records.first.keys : []
      keys.map do |k|
        {
          name: k.to_s,
          type: "UNKNOWN",
          size: nil,
          decimals: nil,
          nullable: true,
          primary_key: false
        }
      end
    end

    def escape_csv(value, separator)
      str = value.to_s
      if str.include?(separator) || str.include?('"') || str.include?("\n")
        "\"#{str.gsub('"', '""')}\""
      else
        str
      end
    end
  end
end
