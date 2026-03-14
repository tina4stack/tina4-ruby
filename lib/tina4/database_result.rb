# frozen_string_literal: true
require "json"

module Tina4
  class DatabaseResult
    include Enumerable

    attr_reader :records, :sql, :count

    def initialize(records = [], sql: "")
      @records = records || []
      @sql = sql
      @count = @records.length
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

    def to_array
      @records.map do |record|
        record.is_a?(Hash) ? record : record.to_h
      end
    end

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

    def to_paginate(page: 1, per_page: 10)
      total = @records.length
      total_pages = (total.to_f / per_page).ceil
      offset = (page - 1) * per_page
      page_records = @records[offset, per_page] || []
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
