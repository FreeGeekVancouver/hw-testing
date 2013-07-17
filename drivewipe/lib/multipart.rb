# -*- coding: utf-8 -*-

module Multipart
  VERSION = "1.0.0" unless const_defined?(:VERSION)

  # Formats a given hash as a multipart form post
  # If a hash value responds to :string or :read messages, then it is
  # interpreted as a file and processed accordingly; otherwise, it is
  # assumed to be a string
  class Post
    USERAGENT =
        "Multipart::Post v#{VERSION}" unless const_defined?(:USERAGENT)

    unless const_defined?(:BOUNDARY)
      BOUNDARY = "0123456789ABLEWASIEREISAWELBA9876543210"
    end

    unless const_defined?(:CONTENT_TYPE)
      CONTENT_TYPE = "multipart/form-data; boundary=#{ BOUNDARY }"
    end

    HEADER = {
      "Content-Type" => CONTENT_TYPE,
      "User-Agent" => USERAGENT
    } unless const_defined?(:HEADER)

    def self.prepare_query(params)
      fp = []

      params.each do |k, v|
        # Are we trying to make a file parameter?
        if v.respond_to?(:path) and v.respond_to?(:read) then
          fp.push(FileParam.new(k, v))
        # We must be trying to make a regular parameter
        else
          fp.push(StringParam.new(k, v))
        end
      end

      # Assemble the request body using the special multipart format
      query = fp.collect {|p|
        "--" + BOUNDARY + "\r\n" + p.to_multipart
      }.join("")  + "--" + BOUNDARY + "--"

      return query, HEADER
    end
  end

  private

  # Formats a basic string key/value pair for inclusion with a multipart post
  class StringParam
    attr_accessor :k, :v

    def initialize(k, v)
      @k = k
      @v = v
    end

    def to_multipart
      return "Content-Disposition: form-data; " +
        "name=\"#{CGI::escape(k)}\"\r\n\r\n#{v}\r\n"
    end
  end

  # Formats the contents of a file or string for inclusion with a multipart
  # form post
  class FileParam
    attr_accessor :k, :filename, :content

    def initialize(k, f)
      @k = k
      @filename = f.path
      @content = f.read
    end

    def to_multipart
      # If we can tell the possible mime-type from the filename, use the
      # first in the list; otherwise, use "application/octet-stream"
      return "Content-Disposition: form-data; " +
        "name=\"#{CGI::escape(k)}\"; filename=\"#{ filename }\"\r\n" +
        "Content-Type: application/octet-stream\r\n\r\n#{ content }\r\n"
    end
  end
end
