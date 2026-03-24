# frozen_string_literal: true
require "json"

module Tina4
  class DatabaseResult
    include Enumerable

    attr_reader :records, :columns, :count, :limit, :offset, :sql,
                :affected_rows, :last_id, :error

    def initialize(records = [], sql: "", columns: [], count: nil, limit: 10, offset: 0,
                   affected_rows: 0, last_id: nil, error: nil)
      @records = records || []
      @sql = sql
      @columns = columns.empty? && !@records.empty? ? @records.first.keys : columns
      @count = count || @records.length
      @limit = limit
      @offset = offset
      @affected_rows = affected_rows
      @last_id = last_id
      @error = error
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

    private

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
