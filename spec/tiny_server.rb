#
# Author:: Daniel DeLeo (<dan@chef.io>)
# Copyright:: Copyright 2010-2016, Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "rubygems"
require "webrick"
require "webrick/https"
require "rack"
require "thread"
require "singleton"
require "open-uri"
require "chef/config"

module TinyServer

  class Server < Rack::Server

    attr_writer :app

    def self.setup(options = nil, &block)
      tiny_app = new(options)
      app_code = Rack::Builder.new(&block).to_app
      tiny_app.app = app_code
      tiny_app
    end

    def shutdown
      server.shutdown if server
    end
  end

  class Manager

    # 5 == debug, 3 == warning
    LOGGER = WEBrick::Log.new(STDOUT, 3)
    DEFAULT_OPTIONS = {
      :server => "webrick",
      :Port => 9000,
      :Host => "localhost",
      :environment => :none,
      :Logger => LOGGER,
      :AccessLog => [] # Remove this option to enable the access log when debugging.
    }

    def initialize(options = nil)
      @options = options ? DEFAULT_OPTIONS.merge(options) : DEFAULT_OPTIONS
      @creator = caller.first
      @action_queue = Queue.new
    end

    attr_reader :options
    attr_reader :creator
    attr_reader :server

    def start(timeout = 5)
      raise "Server already started!" if server

      # The listeners are initialized here. We do it outside the thread so an
      # exception will be thrown if we fail rather than the thread failing.
      @server = Server.setup(**options, StartCallback: proc { action_queue << :start }, StopCallback: proc { action_queue << :stop }) do
        run API.instance
      end
      @old_handler = trap(:INT, "EXIT")

      @server_thread = Thread.new do
        begin
          server.start
        rescue
          STDERR.puts "TinyServer failed in `start`: #{$!}"
          STDERR.puts $!.backtrace
          queue << $!
        end
      end
      # Wait for the first action (either started or something else)
      wait_for_action(timeout)
    end

    def stop(timeout = 5)
      if old_handler
        trap(:INT, old_handler)
        @old_handler = nil
      end

      if server
        server.shutdown
        # Wait for the stop action.
        wait_for_action(timeout)
      end
    end

    private

    attr_reader :action_queue
    attr_reader :server_thread
    attr_reader :old_handler

    def cleanup(timeout)
      @server = nil
      if server_thread
        # Wait for a normal shutdown first
        begin
          server_thread.join(timeout)
        rescue
          server_thread.kill
          server_thread.join(timeout)
        end
        @server_thread = nil
      end
      @started = nil
    end

    def wait_for_action(timeout = 5)
      Timeout.timeout(timeout) do
        action = action_queue.pop
        case action
        when :start
          @started = true
        when :stop
          started = @started
          cleanup(timeout)
          raise "Stopped server before it could even start" unless started
        # Otherwise it's an exception that needs re-raising
        else
          cleanup(timeout)
          raise action
        end
        action
      end
    end
  end

  class API
    include Singleton

    GET     = "GET"
    PUT     = "PUT"
    POST    = "POST"
    DELETE  = "DELETE"

    attr_reader :routes

    def initialize
      clear
    end

    def clear
      @routes = { GET => [], PUT => [], POST => [], DELETE => [] }
    end

    def get(path, response_code, data = nil, headers = nil, &block)
      @routes[GET] << Route.new(path, Response.new(response_code, data, headers, &block))
    end

    def put(path, response_code, data = nil, headers = nil, &block)
      @routes[PUT] << Route.new(path, Response.new(response_code, data, headers, &block))
    end

    def post(path, response_code, data = nil, headers = nil, &block)
      @routes[POST] << Route.new(path, Response.new(response_code, data, headers, &block))
    end

    def delete(path, response_code, data = nil, headers = nil, &block)
      @routes[DELETE] << Route.new(path, Response.new(response_code, data, headers, &block))
    end

    def call(env)
      if response = response_for_request(env)
        response.call
      else
        debug_info = { :message => "no data matches the request for #{env['REQUEST_URI']}",
                       :available_routes => @routes, :request => env }
        # Uncomment me for glorious debugging
        # pp :not_found => debug_info
        [404, { "Content-Type" => "application/json" }, [ Chef::JSONCompat.to_json(debug_info) ]]
      end
    end

    def response_for_request(env)
      if route = @routes[env["REQUEST_METHOD"]].find { |route| route.matches_request?(env["REQUEST_URI"]) }
        route.response
      end
    end
  end

  class Route
    attr_reader :response

    def initialize(path_spec, response)
      @path_spec, @response = path_spec, response
    end

    def matches_request?(uri)
      uri = URI.parse(uri).request_uri
      @path_spec === uri
    end

    def to_s
      "#{@path_spec} => (#{@response})"
    end

  end

  class Response
    HEADERS = { "Content-Type" => "application/json" }

    def initialize(response_code = 200, data = nil, headers = nil, &block)
      @response_code, @data = response_code, data
      @response_headers = headers ? HEADERS.merge(headers) : HEADERS
      @block = block_given? ? block : nil
    end

    def call
      data = @data || @block.call
      [@response_code, @response_headers, Array(data)]
    end

    def to_s
      "#{@response_code} => #{(@data || @block)}"
    end

  end

end
