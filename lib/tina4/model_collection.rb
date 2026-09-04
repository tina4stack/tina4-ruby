# frozen_string_literal: true

module Tina4
  # A list of ORM models that ALSO carries the total rows matching the query.
  #
  # ModelCollection is what the ORM read queries (+where+ / +select+ / +find+
  # (filter form) / +all+ / +with_trashed+) return. It IS an Array -- iterate it,
  # index it, slice it, map it, count it, serialise it to JSON -- so every
  # existing caller keeps working unchanged. It adds one thing: the TOTAL number
  # of rows matching the query's filter, independent of +limit+ / +offset+.
  #
  # The total is free. Every one of those methods already runs +db.fetch+, which
  # computes a +SELECT COUNT(*)+ probe and hands it back on +DatabaseResult#count+;
  # the ORM used to hydrate the page of models and throw that count away. This
  # class carries it instead, so a caller with 20 models on the page can still
  # learn there are 250 rows in the set -- with ZERO extra queries.
  #
  # Uniform across all four Tina4 frameworks (ADR-0064). Same concept, language-
  # idiomatic accessor name:
  #
  #     Python / Ruby : get_total_records   to_paginate
  #     PHP / Node    : getTotalRecords     toPaginate
  #
  # The accessor is a METHOD, not a +.total+ property, on purpose: +Array#count+
  # already exists, so a +.count+ would shadow a built-in. +DatabaseResult+ keeps
  # its +.count+ (it is not an Array); both expose the identical seven-key
  # +to_paginate+ envelope (ADR-0043).
  class ModelCollection < Array
    # The SQL limit / offset that produced this page -- carried for to_paginate.
    # The total is exposed only through get_total_records (the documented
    # accessor), never a bare reader, so it reads the same in every framework.
    attr_reader :limit, :offset

    # @param items  [Array] the page of hydrated model instances
    # @param total  [Integer] total rows matching the query's filter (ignores limit/offset)
    # @param limit  [Integer] the SQL limit that produced this page (0 = none applied)
    # @param offset [Integer] the SQL offset that produced this page
    def initialize(items = [], total: 0, limit: 0, offset: 0)
      super()
      concat(items || [])
      @total = total.to_i
      @limit = limit.to_i
      @offset = offset.to_i
    end

    # Total rows matching the query's filter, ignoring limit / offset.
    #
    # This is the whole point of the collection: the page slice you are iterating
    # is capped by +limit+, but this number is the full count of matching rows --
    # what a pager needs to render "page 3 of 13". Sourced from the fetch COUNT
    # probe (+DatabaseResult#count+); no second query is fired.
    def get_total_records
      @total
    end

    # The canonical pagination envelope -- seven snake_case keys, identical to
    # +DatabaseResult#to_paginate+ (ADR-0043) and to the other three frameworks'
    # +toPaginate+:
    #
    #   records     the page's rows as model hashes (never re-sliced)
    #   total       get_total_records -- the true total for the filter
    #   page        floor(offset / per_page) + 1
    #   per_page    the query's limit
    #   total_pages ceil(total / per_page)
    #   limit       the SQL limit actually applied
    #   offset      the SQL offset actually applied
    #
    # +records+ are model hashes (via +#to_h+) so the JSON a client sees matches
    # +DatabaseResult+ exactly -- the result is uniform whether the route returned
    # a raw +db.fetch+ or an ORM query.
    def to_paginate
      per_page    = @limit > 0 ? @limit : size
      page        = per_page > 0 ? (@offset / per_page) + 1 : 1
      total       = @total
      total_pages = per_page > 0 ? [1, (total.to_f / per_page).ceil].max : 1
      {
        records: map { |model| model.respond_to?(:to_h) ? model.to_h : model },
        total: total,
        page: page,
        per_page: per_page,
        total_pages: total_pages,
        limit: per_page,
        offset: @offset
      }
    end
  end
end
