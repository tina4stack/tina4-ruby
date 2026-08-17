# frozen_string_literal: true

require "json"

module Tina4
  class SpatialNotSupportedError < StandardError; end

  # Immutable SRID-aware longitude/latitude point (ADR-0057).
  class Point
    DEFAULT_SRID = 4326
    EWKB_SRID = 0x20000000
    EWKB_M = 0x40000000
    EWKB_Z = 0x80000000

    attr_reader :lon, :lat, :srid

    def initialize(lon, lat, srid: DEFAULT_SRID)
      raise ArgumentError, "Point longitude and latitude must be numbers" if lon == true || lon == false || lat == true || lat == false
      @lon = Float(lon)
      @lat = Float(lat)
      @srid = Integer(srid)
      raise ArgumentError, "Point longitude and latitude must be finite" unless @lon.finite? && @lat.finite?
      if @srid == DEFAULT_SRID
        raise ArgumentError, "Point longitude #{@lon} is outside -180..180; Tina4 uses longitude, latitude order" unless (-180.0..180.0).cover?(@lon)
        raise ArgumentError, "Point latitude #{@lat} is outside -90..90; Tina4 uses longitude, latitude order" unless (-90.0..90.0).cover?(@lat)
      end
      freeze
    rescue TypeError, ArgumentError => e
      raise e if e.message.start_with?("Point ")
      raise ArgumentError, "Point longitude, latitude and SRID must be numeric"
    end

    def wkt = "POINT(#{format_coordinate(@lon)} #{format_coordinate(@lat)})"
    def ewkt = "SRID=#{@srid};#{wkt}"
    def geojson = { type: "Point", coordinates: [@lon, @lat] }
    def to_h = geojson
    def to_a = [@lon, @lat]
    def to_json(*args) = geojson.to_json(*args)

    def self.parse(value, srid: DEFAULT_SRID)
      return value if value.is_a?(Point)
      if value.is_a?(Array)
        raise ArgumentError, "Point coordinate pair needs longitude and latitude" if value.length < 2
        return new(value[0], value[1], srid: srid)
      end
      return from_geojson(value, srid) if value.is_a?(Hash)
      if value.is_a?(String)
        text = value.strip
        match = text.match(/\A(?:SRID\s*=\s*(\d+)\s*;\s*)?POINT\s*(?:Z|M|ZM)?\s*\(\s*([-+0-9.eE]+)\s+([-+0-9.eE]+)(?:\s+[-+0-9.eE]+)*\s*\)\z/i)
        return new(match[2], match[3], srid: match[1] ? match[1].to_i : srid) if match
        raw = [text].pack("H*") if text.length >= 42 && text.length.even? && text.match?(/\A[0-9a-f]+\z/i)
        raw ||= value.b if [0, 1].include?(value.getbyte(0))
        return from_wkb(raw, srid) if raw
      end
      raise ArgumentError, "Point must be Point, [longitude, latitude], WKT/EWKT, GeoJSON or WKB/EWKB"
    end

    def self.geometry_binding(value, srid: DEFAULT_SRID)
      return [parse(value, srid: srid).ewkt, :ewkt] if value.is_a?(Point) || value.is_a?(Array)
      if value.is_a?(Hash)
        geometry = value.fetch(:type, value["type"]).to_s.downcase == "feature" ? (value[:geometry] || value["geometry"]) : value
        type = (geometry[:type] || geometry["type"]).to_s.downcase
        allowed = %w[point linestring polygon multipoint multilinestring multipolygon geometrycollection]
        raise ArgumentError, "GeoJSON geometry has an unsupported type" unless allowed.include?(type)
        return [JSON.generate(geometry), :geojson]
      end
      if value.is_a?(String) && value.match?(/\A\s*(?:SRID\s*=\s*\d+\s*;\s*)?(?:POINT|LINESTRING|POLYGON|MULTIPOINT|MULTILINESTRING|MULTIPOLYGON|GEOMETRYCOLLECTION)\b/i)
        return [value.match?(/\A\s*SRID/i) ? value.strip : "SRID=#{srid};#{value.strip}", :ewkt]
      end
      raise ArgumentError, "Geometry must be Point, coordinate pair, WKT/EWKT or GeoJSON"
    end

    def self.from_geojson(data, srid)
      type = (data[:type] || data["type"]).to_s.downcase
      geometry = type == "feature" ? (data[:geometry] || data["geometry"] || {}) : data
      raise ArgumentError, "Point GeoJSON type must be Point" unless (geometry[:type] || geometry["type"]).to_s.downcase == "point"
      coordinates = geometry[:coordinates] || geometry["coordinates"]
      raise ArgumentError, "Point GeoJSON coordinates must be [longitude, latitude]" unless coordinates.is_a?(Array) && coordinates.length >= 2
      new(coordinates[0], coordinates[1], srid: srid)
    end
    private_class_method :from_geojson

    def self.from_wkb(raw, srid)
      raise ArgumentError, "Point WKB is too short" if raw.bytesize < 21
      little = raw.getbyte(0) == 1
      type_word = raw.byteslice(1, 4).unpack1(little ? "V" : "N")
      offset = 5
      if (type_word & EWKB_SRID) != 0
        srid = raw.byteslice(5, 4).unpack1(little ? "V" : "N")
        offset = 9
      end
      code = (type_word & ~(EWKB_SRID | EWKB_Z | EWKB_M)) % 1000
      raise ArgumentError, "WKB geometry is not a Point" unless code == 1 && raw.bytesize >= offset + 16
      lon, lat = raw.byteslice(offset, 16).unpack(little ? "E2" : "G2")
      new(lon, lat, srid: srid)
    end
    private_class_method :from_wkb

    private

    def format_coordinate(value)
      text = format("%.15g", value)
      text == "-0" ? "0" : text
    end
  end
end
