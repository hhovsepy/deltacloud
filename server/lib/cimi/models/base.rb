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

require 'xmlsimple'

# The base class for any CIMI object that we either read from a request or
# write as a response. This class handles serializing/deserializing XML and
# JSON into a common form.
#
# == Defining the schema
#
# The conversion of XML and JSON into internal objects is based on a schema
# that is defined through a DSL:
#
#   class Machine < CIMI::Model::Base
#     text :status
#     href :meter
#     array :volumes do
#       scalar :href, :attachment_point, :protocol
#     end
#   end
#
# The DSL automatically takes care of converting identifiers from their
# underscored form to the camel-cased form used by CIMI. The above class
# can be used in the following way:
#
#   machine = Machine.from_xml(some_xml)
#   if machine.status == "UP"
#     ...
#   end
#   sda = machine.volumes.find { |v| v.attachment_point == "/dev/sda" }
#   handle_meter(machine.meter.href)
#
# The keywords for the DSL are
#   [scalar(names, ...)]
#     Define a scalar attribute; in JSON, this is represented as a string
#     property. In XML, this can be represented in a number of ways,
#     depending on whether the option :text is set:
#       * :text not set: attribute on the enclosing element
#       * :text == :direct: the text content of the enclosing element
#       * :text == :nested: the text content of an element +<name>...</name>+
#   [text(names)]
#     A shorthand for +scalar(names, :text => :nested)+, i.e., for
#     attributes that in XML are represented by their own tags
#   [href(name)]
#     A shorthand for +struct name { scalar :href }+; in JSON, this is
#     represented as +{ name: { "href": string } }+, and in XML as +<name
#     href="..."/>+
#   [struct(name, opts, &block)]
#     A structured subobject; the block defines the schema of the
#     subobject. The +:content+ option can be used to specify the attribute
#     that should receive the content of hte corresponding XML element
#   [array(name, opts, &block)]
#     An array of structured subobjects; the block defines the schema of
#     the subobjects.
#   [collection(name, opts)]
#     A collection of associated objects; use the +:class+ option to
#     specify the type of the collection entries

module CIMI::Model

  def self.register_as_root_entity!(klass, opts = {})
    @root_entities ||= []
    @root_entities << klass
    name = klass.name.split("::").last.pluralize
    unless CIMI::Model::CloudEntryPoint.href_defined?(name)
      params = {}
      if opts[:as]
        params[:xml_name] = params[:json_name] = opts[:as]
      end
      CIMI::Model::CloudEntryPoint.send(:href, name.underscore, params)
    end
  end

  def self.root_entities
    @root_entities || []
  end

end

class CIMI::Model::Resource

  #
  # We keep the values of the attributes in a hash
  #
  attr_reader :attribute_values

  CMWG_NAMESPACE = "http://schemas.dmtf.org/cimi/1"

  # Keep the list of all attributes in an array +attributes+; for each
  # attribute, we also define a getter and a setter to access/change the
  # value for that attribute
  class << self

    def <<(model)
      clone_base_schema unless base_schema_cloned?
      member_name = model.name.split("::").last
      if ::Struct.const_defined?("CIMI_#{member_name}")
        puts "Removing struct"
        ::Struct.send(:remove_const, "CIMI_#{member_name}")
      end
      member_symbol = member_name.underscore.pluralize.to_sym
      members = CIMI::Model::Schema::Array.new(member_symbol)
      members.struct.schema.attributes = model.schema.attributes
      base_schema.attributes << members
    end

    def base_schema
      @schema ||= CIMI::Model::Schema.new
    end

    def clone_base_schema
      @schema_duped = true
      @schema = Marshal::load(Marshal.dump(superclass.base_schema))
    end

    def base_schema_cloned?
      @schema_duped
    end

    private :clone_base_schema, :base_schema_cloned?

    def inherited(child)
      child.instance_eval do
        def schema
          base_schema_cloned? ? @schema : clone_base_schema
        end
      end
    end

    def add_attributes!(names, attr_klass, &block)
      if self.respond_to? :schema
        schema.add_attributes!(names, attr_klass, &block)
      else
        base_schema.add_attributes!(names, attr_klass, &block)
      end
      names.each do |name|
        define_method(name) { self[name] }
        define_method(:"#{name}=") { |newval| self[name] = newval }
      end
    end

    # Return Array of links to current CIMI object
    def all_uri(context)
      self.all(context).map { |e| { :href => e.id } }
    end
  end

  extend CIMI::Model::Schema::DSL

  def [](a)
    @attribute_values[a]
  end

  def []=(a, v)
    @attribute_values[a] = self.class.schema.convert(a, v)
  end

  # Prepare to serialize
  def prepare
    self.class.schema.collections.map { |coll| coll.name }.each do |n|
      self[n].href = "#{self.id}/#{n}" unless self[n].href
      self[n].id = "#{self.id}/#{n}" if !self[n].entries.empty?
    end
  end

  #
  # Factory methods
  #
  def initialize(values = {})
    names = self.class.schema.attribute_names
    @attribute_values = names.inject({}) do |hash, name|
      hash[name] = self.class.schema.convert(name, values[name])
      hash
    end
  end

  # Construct a new object from the XML representation +xml+
  def self.from_xml(text)
    xml = XmlSimple.xml_in(text, :force_content => true)
    model = self.new
    @schema.from_xml(xml, model)
    model
  end

  # Construct a new object
  def self.from_json(text)
    json = JSON::parse(text)
    model = self.new
    @schema.from_json(json, model)
    model
  end

  def self.parse(text, content_type)
    if content_type == "application/xml"
      from_xml(text)
    elsif content_type == "application/json"
      from_json(text)
    else
      raise "Can not parse content type #{content_type}"
    end
  end

  #
  # Serialize
  #

  def self.xml_tag_name
    self.name.split("::").last
  end

  def self.resource_uri
    CMWG_NAMESPACE + "/" + self.name.split("::").last
  end

  def self.to_json(model)
    json = @schema.to_json(model)
    json[:resourceURI] = resource_uri
    JSON::unparse(json)
  end

  def self.to_xml(model)
    xml = @schema.to_xml(model)
    xml["xmlns"] = CMWG_NAMESPACE
    xml["resourceURI"] = resource_uri
    XmlSimple.xml_out(xml, :root_name => xml_tag_name)
  end

  def to_json
    self.class.to_json(self)
  end

  def to_xml
    self.class.to_xml(self)
  end

  def filter_by(filter_opts)
    return self if filter_opts.nil?
    return filter_attributes(filter_opts.split(',').map{ |a| a.intern }) if filter_opts.include? ','
    case filter_opts
      when /^([\w\_]+)$/ then filter_attributes([$1.intern])
      when /^([\w\_]+)\[(\d+\-\d+)\]$/ then filter_by_arr_range($1.intern, $2)
      when /^([\w\_]+)\[(\d+)\]$/ then filter_by_arr_index($1.intern, $2)
      else self
    end
  end

  def filter_by_arr_index(attr, filter)
    return self unless self.respond_to?(attr)
    self.class.new(attr => [self.send(attr)[filter.to_i]])
  end

  def filter_by_arr_range(attr, filter)
    return self unless self.respond_to?(attr)
    filter = filter.split('-').inject { |s,e| s.to_i..e.to_i }
    self.class.new(attr => self.send(attr)[filter])
  end
end

class CIMI::Model::Base < CIMI::Model::Resource
  #
  # Common attributes for all resources
  #
  text :id, :name, :description, :created

  hash :property

  def filter_attributes(attr_list)
    attrs = attr_list.inject({}) do |result, attr|
      result[attr] = self.send(attr) if self.respond_to?(attr)
      result
    end
    self.class.new(attrs)
  end

  class << self
    def store_attributes_for(context, entity, attrs={})
      stored_attributes = {}
      stored_attributes[:description] = extract_attribute_value('description', attrs) if attrs['description']
      stored_attributes[:name] = extract_attribute_value('name', attrs) if attrs['name']
      stored_attributes[:ent_properties] = extract_attribute_value('properties', attrs).to_json if attrs['properties']
      context.store_attributes_for(entity, stored_attributes)
    end

    # In XML serialization the values stored in attrs are arrays, dues to
    # XmlSimple. This method will help extract values from them
    #
    def extract_attribute_value(name, attrs={})
      return unless attrs[name]
      attrs[name].is_a?(Array) ? attrs[name].first : attrs[name]
    end
  end
end
