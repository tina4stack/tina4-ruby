# frozen_string_literal: true
require "json"

module Tina4
  class DatabaseResult
    include Enumerable

    attr_reader :records, :columns, :count, :limit, :offset, :sql,
                :affected_rows, :last_id, :error

    # `limit` is the row cap ACTUALLY APPLIED to the statement that produced
    # these records — what Database#fetch appended — and `0` means none was
    # (an explicit no-limit read, SQL carrying its own trailing LIMIT, or a
    # write). The default used to be `10`: Database#fetch_direct never passed
    # limit:/offset:, so that untouched default was reported on EVERY fetch
    # whatever limit ran — and 10 is the stale v2 documentation number that the
    # buried PHP row-cap test also asserted as the cap. 0 says "no cap recorded"
    # instead of quietly naming a number nothing applied.
    def initialize(records = [], sql: "", columns: [], count: nil, limit: 0, offset: 0,
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

    # Index / slice access into the result rows.
    #
    # ``result[0]`` is documented (book ch5 §4 "Index Access"). Delegating
    # straight to the materialised rows means every Array subscript form
    # works — ``result[0]``, ``result[-1]``, ``result[1, 2]`` and
    # ``result[1..3]`` — and matches Python's ``DatabaseResult.__getitem__``,
    # which forwards to its records list.
    def [](*args)
      @records[*args]
    end

    # Implicit array coercion, so a DatabaseResult can be splatted and used
    # anywhere an Array is expected (``a, b = result``, ``[*result]``).
    def to_ary
      @records.dup
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

    # Describe the page this result already IS. Takes NO arguments (ADR-0043).
    #
    # Every field is derived from the query that produced this result:
    #   per_page    = the query's limit
    #   page        = floor(offset / limit) + 1
    #   total       = the true total for the filter (@count, from the COUNT probe
    #                 Database#fetch runs when it applied the limit), NEVER the
    #                 number of rows this page returned
    #   total_pages = ceil(total / per_page)
    #   records     = the rows the query returned, VERBATIM, never re-sliced
    #   limit/offset= the SQL limit/offset actually applied
    #
    # The envelope is EXACTLY seven snake_case keys, identical in all four
    # frameworks: records, total, page, per_page, total_pages, limit, offset. The
    # old duplicate/camelCase spellings (data, count, totalPages, has_next,
    # has_prev) are gone - a JSON key is data and does not change spelling by host
    # language, so the same integer never ships twice under two names.
    #
    # PASSING ANY ARGUMENT RAISES. A DatabaseResult holds no connection, so an
    # argument could only re-slice rows already in memory and then report
    # total_pages for pages it can never reach. To read page N, FETCH page N
    # (limit + offset) and call this with no arguments. The removed page:/per_page:
    # slicing mode is a hard error, never a silent reinterpretation - superseding
    # the in-memory slice GitHub #106 asked for.
    #
    # MEASURED 2026-08-05 on a real 250-row table read with limit=20 offset=40
    # (page 3 of 13): the old two-mode method re-sliced @records by the ABSOLUTE
    # offset (40) against an array already only 20 long and returned ZERO records
    # for a valid page, while still shipping a page number and total - an envelope
    # that looked authoritative and was empty.
    def to_paginate(*args, **kwargs)
      unless args.empty? && kwargs.empty?
        raise ArgumentError,
              "to_paginate takes no arguments (ADR-0043): it describes the page " \
              "this result already IS, derived from the query that produced it. A " \
              "DatabaseResult holds no connection, so an argument could only " \
              "re-slice rows already in memory and lie about total_pages. To read " \
              "another page, FETCH it - fetch(sql, limit: per_page, offset: " \
              "(page - 1) * per_page) - then call to_paginate with no arguments."
      end

      per_page    = @limit.to_i > 0 ? @limit.to_i : @records.size
      page        = per_page > 0 ? (@offset.to_i / per_page) + 1 : 1
      total       = @count
      total_pages = per_page > 0 ? [1, (total.to_f / per_page).ceil].max : 1

      {
        records: @records,
        total: total,
        page: page,
        per_page: per_page,
        total_pages: total_pages,
        limit: per_page,
        offset: @offset.to_i
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
          # Symbol OR string key, because a driver row may arrive either way.
          # The `:primary` / `"primary"` fallbacks that used to sit here were
          # dead: no Ruby driver has ever emitted that spelling. It was mirroring
          # PHP's odd `primary`, which PHP itself has now dropped for `primaryKey`.
          primary_key: col[:primary_key] || col["primary_key"] || false
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
