#
# Copyright (C) 2010  Red Hat, Inc.
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.  The
# ASF licenses this file to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance with the
# License.  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations
# under the License.

require 'lib/string'

module DeltaCloud

    class BaseObjectParamError < Exception; end
    class NoHandlerForMethod < Exception; end

    # BaseObject model basically provide the basic operation around
    # REST model, like defining a links between different objects,
    # element with text values, or collection of these elements
    class BaseObject
      attr_reader :id, :url, :client, :base_name
      attr_reader :objects

      alias :uri :url

      # For initializing new object you require to set
      # id, url, client and name attribute.
      def initialize(opts={}, &block)
        @id, @url, @client, @base_name = opts[:id], opts[:url], opts[:client], opts[:name]
        @objects = []
        raise BaseObjectParamError if @id.nil? or @url.nil? or @client.nil? or @base_name.nil?
        yield self if block_given?
      end

      # This method add link to another object in REST model
      # XML syntax: <link rel="destroy" href="http://localhost/api/resource" method="post"/>
      def add_link!(object_name, id)
        @objects << {
          :type => :link,
          :method_name => object_name.sanitize,
          :id => id
        }
        @objects << {
          :type => :text,
          :method_name => "#{object_name.sanitize}_id",
          :value => id
        }
      end

      # Method add property for hardware profile
      def add_hwp_property!(name, property, type)
        hwp_property=case type
          when :float then DeltaCloud::HWP::FloatProperty.new(property, name)
          when :integer then DeltaCloud::HWP::Property.new(property, name)
        end
        @objects << {
          :type => :property,
          :method_name => name.sanitize,
          :property => hwp_property
        }
      end

      # This method define text object in REST model
      # XML syntax: <name>Instance 1</name>
      def add_text!(object_name, value)
        @objects << {
          :type => :text,
          :method_name => object_name.sanitize,
          :value => value
        }
      end

      # This method define collection of text elements inside REST model
      # XML syntax: <addresses>
      #               <address>127.0.0.1</address>
      #               <address>127.0.0.2</address>
      #             </addresses>
      def add_collection!(collection_name, values=[])
        @objects << {
          :type => :collection,
          :method_name => collection_name.sanitize,
          :values => values
        }
      end

      # Basic method hander. This define a way how value from property
      # will be returned
      def method_handler(m, args=[])
        case m[:type]
          when :link then return @client.send(m[:method_name].singularize, m[:id])
          when :text then return m[:value]
          when :property then return m[:property]
          when :collection then return m[:values]
          else raise NoHandlerForMethod
        end
      end

      def method_missing(method_name, *args)
        # First of all search throught array for method name
        m = search_for_method(method_name)
        if m.nil?
          warn "[WARNING] Method unsupported by API: '#{self.class}.#{method_name}(#{args.inspect})'"
          return nil
        else
          # Call appropriate handler for method
          method_handler(m, args)
        end
      end

      private

      def search_for_method(name)
        @objects.select { |o| o[:method_name] == "#{name}" }.first
      end

    end

    class ActionObject < BaseObject

      def initialize(opts={}, &block)
        super(opts)
        @action_urls = opts[:action_urls] || []
        @actions = []
      end

      # This trigger is called right after action. 
      # This method does nothing inside ActionObject
      # but it can be redifined and used in meta-programming
      def action_trigger(action)
      end

      def add_action_link!(id, link)
        m = {
          :type => :action_link,
          :method_name => "#{link['rel'].sanitize}!",
          :id => id,
          :href => link['href'],
          :rel => link['rel'].sanitize,
          :method => link['method'].sanitize
        }
        @objects << m
        @actions << [m[:rel], m[:href]]
        @action_urls << m[:href]
      end

      def actions
        @objects.select {|o| o[:type].eql?(:action_link) }.collect { |o| [o[:rel], o[:href]] }
      end

      def action_urls
        actions.collect { |a| a.last }
      end

      alias :base_method_handler :method_handler

      # First call BaseObject method handler,
      # then, if not method found try ActionObject handler
      def method_handler(m, args=[])
        begin
          base_method_handler(m, args)
        rescue NoHandlerForMethod
          case m[:type]
            when :action_link then do_action(m)
            else raise NoHandlerForMethod
          end
        end
      end

      private

      def do_action(m)
        @client.request(:"#{m[:method]}", m[:href], {}, {})
        action_trigger(m[:rel])
      end

    end

    class StateFullObject < ActionObject
      attr_reader :state

      def initialize(opts={}, &block)
        super(opts)
        @state = opts[:initial_state] || ''
        add_default_states!
      end

      def add_default_states!
        @objects << {
          :method_name => 'stopped?',
          :type => :state,
          :state => 'STOPPED'
        }
        @objects << {
          :method_name => 'running?',
          :type => :state,
          :state => 'RUNNING'
        }
        @objects << {
          :method_name => 'pending?',
          :type => :state,
          :state => 'PENDING'
        }
        @objects << {
          :method_name => 'shutting_down?',
          :type => :state,
          :state => 'SHUTTING_DOWN'
        }
      end

      def action_trigger(action)
        # Refresh object state after action
        @new_state_object = @client.send(self.base_name, self.id)
        @state = @new_state_object.state
        self.update_actions!
      end

      alias :action_method_handler :method_handler

      def method_handler(m, args=[])
        begin
          action_method_handler(m, args)
        rescue NoHandlerForMethod
          case m[:type]
            when :state then evaluate_state(m[:state], @state)
            else raise NoHandlerForMethod
          end
        end
      end

#      private

      def evaluate_state(method_state, current_state)
        method_state.eql?(current_state)
      end

      def action_objects
        @objects.select { |o| o[:type] == :action_link }
      end

      def update_actions!
        new_actions = @new_state_object.action_objects
        @objects.reject! { |o| o[:type] == :action_link }
        @objects = (@objects + new_actions)
      end

    end

    def self.add_class(name, parent=:base)
      parent_class = case parent
        when :base then BaseObject
        when :action then ActionObject
        when :state then StateFullObject
      end
      begin
        return API.const_get(name.classify)
      rescue NameError
        API.module_eval("class #{name.classify} < #{parent_class.to_s}; end")
        new_class = API.const_get(name.classify)
        @defined_classes ||= []
        @defined_classes << new_class
        new_class
      end
    end

    def self.guess_model_type(response)
      response = Nokogiri::XML(response.to_s)
      return :action if ((response/'//actions').length == 1) and ((response/'//state').length == 0)
      return :state if ((response/'//actions').length == 1) and ((response/'//state').length == 1)
      return :base
    end

end