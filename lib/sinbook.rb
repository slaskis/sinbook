begin
  require 'sinatra/base'
rescue LoadError
  retry if require 'rubygems'
  raise
end

module Sinatra
  require 'digest/md5'
  require 'json'

  class FacebookObject
    def initialize app
      @app = app

      @api_key = app.options.facebook_api_key
      @secret = app.options.facebook_secret
      @app_id = app.options.facebook_app_id
      @url = app.options.facebook_url
      @callback = app.options.facebook_callback
    end
    attr_reader :app
    attr_accessor :api_key, :secret
    attr_writer :url, :callback, :app_id

    def app_id
      @app_id || self[:app_id]
    end

    def url postfix=nil
      postfix ? "#{@url}#{postfix}" : @url
    end

    def callback postfix=nil
      postfix ? "#{@callback}#{postfix}" : @callback
    end

    def addurl
      "http://apps.facebook.com/add.php?api_key=#{self.api_key}"
    end

    def appurl
      "http://www.facebook.com/apps/application.php?id=#{self.app_id}"
    end

    def require_login!
      if valid?
        redirect addurl unless params[:user]
      else
        app.redirect url
      end
    end

    def redirect url
      url = self.url + url unless url =~ /^http/
      app.body "<fb:redirect url='#{url}'/>"
      throw :halt
    end

    def params
      return {} unless valid?
      app.env['facebook.params'] ||= \
        app.params.inject({}) do |h,(k,v)|
          next h unless k =~ /^(?:fb_sig|#{self.api_key})_(.+)$/
          k = $1.to_sym
          case $1
          when 'friends'
            h[k] = v.split(',').map{|e|e.to_i}
          when /time$/
            h[k] = Time.at(v.to_f)
          when 'expires'
            v = v.to_i
            h[k] = v>0 ? Time.at(v) : v
          when 'user', 'app_id', 'canvas_user'
            h[k] = v.to_i
          when /^(logged_out|position_|in_|is_|added)/
            h[k] = v=='1'
          else
            h[k] = v
          end
          h
        end
    end

    def [] key
      params[key]
    end

    def valid?
      app.params.merge!( app.request.cookies )
      return false unless app.params['fb_sig'] || app.params[self.api_key]
      sig = Digest::MD5.hexdigest(app.params.map{|k,v| "#{$1}=#{v}" if k =~ /^(?:fb_sig|#{self.api_key})_(.+)$/ }.compact.sort.join+self.secret)
      app.env['facebook.valid?'] ||= \
        app.params['fb_sig'] == sig || \
        app.params[self.api_key] == sig
    end

    class APIProxy
      Types = %w[
        admin
        application
        auth
        batch
        comments
        data
        events
        fbml
        feed
        fql
        friends
        groups
        links
        liveMessage
        notes
        notifications
        pages
        photos
        profile
        status
        stream
        users
        video
      ]

      alias :__class__ :class
      alias :__inspect__ :inspect
      instance_methods.each { |m| undef_method m unless m =~ /^__/ }
      alias :inspect :__inspect__

      def initialize name, obj
        @name, @obj = name, obj
      end

      def method_missing method, opts = {}
        @obj.request "#{@name}.#{method}", opts
      end
    end

    APIProxy::Types.each do |n|
      class_eval %[
        def #{n}
          (@proxies||={})[:#{n}] ||= APIProxy.new(:#{n}, self)
        end
      ]
    end

    def request method, opts = {}
      if method == 'photos.upload'
        image = opts.delete :image
      end

      opts = { :api_key => self.api_key,
               :call_id => Time.now.to_f,
               :format => 'JSON',
               :v => '1.0',
               :session_key => %w[ photos.upload ].include?(method) ? nil : params[:session_key],
               :method => method }.merge(opts)

      args = opts.map{ |k,v|
                       next nil unless v

                       "#{k}=" + case v
                                 when Hash
                                   v.to_json
                                 when Array
                                   if k == :tags
                                     v.to_json
                                   else
                                     v.join(',')
                                   end
                                 else
                                   v.to_s
                                 end
                     }.compact.sort

      sig = Digest::MD5.hexdigest(args.join+self.secret)

      if method == 'photos.upload'
        data = MimeBoundary
        data += opts.merge(:sig => sig).inject('') do |buf, (key, val)|
          if val
            buf << (MimePart % [key, val])
          else
            buf
          end
        end
        data += MimeImage % ['upload.jpg', 'jpg', image.respond_to?(:read) ? image.read : image]
      else
        data = Array["sig=#{sig}", *args.map{|a| a.gsub('&','%26') }].join('&')
      end

      ret = self.class.request(data, method == 'photos.upload')

      ret = if ['true', '1'].include? ret
              true
            elsif ['false', '0'].include? ret
              false
            elsif ret[0..0] == '"'
              ret[1..-2]
            elsif (n = Integer(ret) rescue nil)
              n
            else
              begin
                JSON.parse(ret)
              rescue JSON::ParserError
                puts "Error parsing #{ret.inspect}"
                raise
              end
            end

      raise Facebook::Error, ret['error_msg'] if ret.is_a? Hash and ret['error_code']

      ret
    end

    MimeBoundary = "--SoMeTeXtWeWiLlNeVeRsEe\r\n"
    MimePart = %[Content-Disposition: form-data; name="%s"\r\n\r\n%s\r\n] + MimeBoundary
    MimeImage = %[Content-Disposition: form-data; filename="%s"\r\nContent-Type: image/%s\r\n\r\n%s\r\n] + MimeBoundary

    require 'resolv'
    API_SERVER = Resolv.getaddress('api.facebook.com')
    @keepalive = false

    def self.connect
      TCPSocket.new(API_SERVER, 80)
    end

    def self.request data, mime=false
      if @keepalive
        @socket ||= connect
      else
        @socket = connect
      end

      @socket.print "POST /restserver.php HTTP/1.1\r\n"
      @socket.print "Host: api.facebook.com\r\n"
      @socket.print "Connection: keep-alive\r\n" if @keepalive
      if mime
        @socket.print "Content-Type: multipart/form-data; boundary=#{MimeBoundary[2..-3]}\r\n"
        @socket.print "MIME-version: 1.0\r\n"
      else
        @socket.print "Content-Type: application/x-www-form-urlencoded\r\n"
      end
      @socket.print "Content-Length: #{data.length}\r\n"
      @socket.print "\r\n#{data}\r\n"
      @socket.print "\r\n\r\n"

      buf = ''

      while true
        line = @socket.gets
        raise Errno::ECONNRESET unless line

        if line == "\r\n" # end of headers/chunk
          line = @socket.gets # get size of next chunk
          if line.strip! == '0' # 0 sized chunk
            @socket.gets # read last crlf
            break # done!
          end

          buf << @socket.read(line.to_i(16)) # read in chunk
        end
      end

      buf
    rescue Errno::EPIPE, Errno::ECONNRESET
      @socket = nil
      retry
    ensure
      @socket.close if @socket and !@keepalive
    end
  end

  module FacebookHelper
    def facebook
      env['facebook.helper'] ||= FacebookObject.new(self)
    end
    alias fb facebook
  end

  class FacebookSettings
    def initialize app, &blk
      @app = app
      instance_eval &blk
    end
    %w[ api_key secret app_id url callback ].each do |param|
      class_eval %[
        def #{param} val, &blk
          @app.set :facebook_#{param}, val
        end
      ]
    end
  end

  module Facebook
    class Error < StandardError; end

    def facebook &blk
      FacebookSettings.new(self, &blk)
    end

    def self.registered app
      app.helpers FacebookHelper
      app.before(&method(:fix_request_method))
      app.disable :sessions
    end

    def self.fix_request_method app
      if method = app.request.params['fb_sig_request_method']
        app.request.env['REQUEST_METHOD'] = method
      end
    end
  end

  Application.register Facebook
end
