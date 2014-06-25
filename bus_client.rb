require 'rexml/document'
require 'savon'
require 'time'
require 'socket'
require 'active_support/secure_random'

module BusServices
  class BusClient

    XSI_NAME_SPACE_PREFIX = "xmlns:xsi"
    XSI_NAME_SPACE = "http://www.w3.org/2001/XMLSchema-instance"

    def self.call(props, lan_id, &block)
      header = set_header_values props, lan_id
      body = set_body_values props, &block

      client = Savon::Client.new props[:end_point]
      client.request.http.read_timeout = props[:read_timeout] if props[:read_timeout]
      response = client.call! do |soap, http|
        soap.namespaces[XSI_NAME_SPACE_PREFIX] = XSI_NAME_SPACE
        soap.action = props[:action]
        soap.header = header
        config_soap_body soap, body

      end

      fault_container = BusServices::FaultContainer.new(XPathElement.new(response.to_s))
      fault_container.request_url = props[:end_point]
      # ugly, but the only way to get the string
      fault_container.request = client.request.instance_variable_get(:@soap).to_xml
      fault_container
    end

    # This is very unfortunate but we have to parse out the root element name
    # and namespace and explicitly set them onto savon's soap object and then
    # set the children of the root element as the soap body.
    def self.config_soap_body(soap, body)
      doc = REXML::Document.new body
      root = doc.root
      soap.input = root.name
      soap.namespace = root.namespace
      add_root_namespaces soap, root
      soap.body = get_children_as_string root
    end

    def self.add_root_namespaces(soap, root)
      root.namespaces.each do |k,v|
        soap.namespaces["xmlns:#{k}"] = v
      end
    end

    def self.get_children_as_string(root)
      children = ''
      root.elements.each './*' do |child|
        REXML::Formatters::Default.new.write child, children
      end
      children
    end

    def self.set_header_values(props, lan_id)
      header_doc = XPathElement.new get_header_template(props)
      header_doc.get_element :WFContext do |e|
        e.text :messageId, SecureRandom.base64(25)
        e.text :creationTimestamp, Time.now.xmlschema(3)
        e.text :invokerId, Configuration.invoker_id
        e.text :hostName, Socket.gethostname
        e.text :billingAU, Configuration.billing_au
        if props[:wf_context_version] == '2007'
          e.text :applicationId, Configuration.application_id
          e.get_element :initiator do |i|
            i.text :initiatorId, lan_id
            i.text(:initiatorIdType, Configuration.batch_process_lan_id) if lan_id == Configuration.batch_process_lan_id
          end
          e.get_element :originator do |i|
            i.text :originatorId, lan_id
          end
        else
          e.text :activitySourceId, Configuration.activity_source_id
          e.text :activitySourceIdType, Configuration.activity_source_id_type
          e.text :initiatorId, lan_id
          e.text(:initiatorIdType, Configuration.batch_process_lan_id) if lan_id == Configuration.batch_process_lan_id
        end
      end
      header_doc.write
    end

    def self.set_body_values(props)
      body_doc = XPathElement.new get_body_template(props)
      yield body_doc if block_given?
      body_doc.write
    end

    def self.get_header_template(props)
      read_template "wf_context_#{props[:wf_context_version]}.xml"
    end

    def self.get_body_template(props)
      read_template props[:request]
    end

    def self.read_template(filename)
      Configuration.template_load_paths.each do |path|
        filepath = File.join(path, filename)
        return File.read(filepath) if File.exists?(filepath)
      end
      raise "No #{filename} template found in load path #{Configuration.template_load_paths}"
    end

    class XPathElement

      attr_writer :element_locations

      def initialize(node)
        if node.respond_to? :elements
          @node = node
        else
          @node = REXML::Document.new(node)
        end
      end

      def get_element(*elements, &block)
        select_element "./#{elements.collect {|e| dqn(e) }.join('/')}", &block
      end

      def find_element(element, &block)
        select_element "//#{dqn(element)}", &block
      end

      def clone_with_text_values(name, text_values)
        element = @node.get_elements(dqn(name))[0]

        if text_values.empty?
          @node.delete(element) # remove the element in the template if an empty array is passed in
        else
          element.text = text_values[0].dup # dup since frozen strings will throw an error otherwise
          previous_element = element
          text_values[1..-1].each do |text_value|
            new_element = element.clone
            new_element.text = text_value.dup # dup since frozen strings will throw an error otherwise
            @node.insert_after(previous_element, new_element)
          end
        end
      end

      def delete(element)
        @node.elements.each(dqn(element)) do |e|
          @node.delete e
        end
      end

      def text(element, value)
        @node.elements.each(dqn(element)) do |e|
          e.text = value.is_a?(String) ? value.dup : value # dup because text= does a gsub! on the string internally
        end
      end

      def get_text(element)
        text = []
        @node.elements.each(dqn(element)) do |e|
          text << e.get_text.value
        end

        text.length <= 1 ? text.first : text
      end

      def respond_to?(sym)
        element_defined?(sym) || super(sym)
      end

      def element_defined?(sym)
        @element_locations.has_key?(strip_question(sym)) if @element_locations
      end

      def method_missing(sym, *args, &block)
        return element_content(sym) if element_defined?(sym)
        super(sym, *args, &block)
      end

      def strip_question(sym)
        sym.to_s.gsub(/\?$/, '').to_sym
      end

      def booleanize(text)
        text.match(/true/i).present?
      end

      def element_content(sym)
        text = element_text *@element_locations[strip_question(sym)]
        return nil unless text
        return text if text.is_a?(Array)
        sym.to_s =~ /\?$/ ? booleanize(text) : text
      end

      def array_or_first(obj)
        obj.size == 1 ? obj.first : obj
      end

      def element_text(element, text)
        value = []
        find_element element do |general_inquiry|
           value << general_inquiry.get_text(text)
        end
        value.size > 0 ? array_or_first(value) : nil
      end

      def de_qualify_namespace(element)
        "*[local-name()='#{element.to_s}']"
      end

      def select_element(xpath)
        xpath_elements = []
        @node.elements.each(xpath) do |e|
          xpath_element = XPathElement.new e
          xpath_elements << xpath_element
          yield xpath_element if block_given?
        end
        array_or_first xpath_elements
      end

      alias :dqn :de_qualify_namespace

      def write
        node_str = ''
        REXML::Formatters::Default.new.write @node, node_str
        node_str
      end

    end

  end
end
