module Solve360
  module Item
    
    def self.included(model)
      model.extend ClassMethods
      model.send(:include, HTTMultiParty)
      model.instance_variable_set(:@field_mapping, {})
    end
    
    # Base Item fields
    attr_accessor :id, :name, :typeid, :created, :updated, :viewed, :ownership, :flagged
    
    # Base item collections
    attr_accessor :fields, :related_items, :related_items_to_add, :categories, :categories_to_add,
                    :activities
    
    def initialize(attributes = {})
      #puts "\n\nIn initialize:\n#{attributes.inspect}\n\n"
      attributes.symbolize_keys!
      
      self.fields = {}
      self.related_items = []
      self.related_items_to_add = []
      self.categories = []
      self.categories_to_add = []
      self.activities = []
      
      #[:fields, :related_items].each do |collection|
      #  self.send("#{collection}=", attributes[collection]) if attributes[collection]
      #  attributes.delete collection
      #end

      attributes.each do |key, value|
        self.send(:"#{key}=", value) if methods.include?(:"#{key}=")
      end
    end

    def attributes
      {
          id: id,
          name: name,
          type_id: typeid,
          created_at: created,
          updated_at: updated,
          viewed_at: viewed,
          owner_id: ownership,
          flagged: flagged,
          fields: fields,
          related_items: related_items,
          categories: categories,
          activities: activities
      }
    end
    
    # @see Base::map_human_attributes
    def map_human_fields
      self.class.map_human_fields(self.fields)
    end
    
    # Save the attributes for the current record to the CRM
    #
    # If the record is new it will be created on the CRM
    # 
    # @return [Hash] response values from API
    def save
      response = []
      
      if self.ownership.blank?
        self.ownership = Solve360::Config.config.default_ownership
      end
      
      if new_record?
        response = self.class.request(:post, "/#{self.class.resource_name}", to_request)
        
        if !response["response"]["errors"]
          self.id = response["response"]["item"]["id"]
        end
      else
        response = self.class.request(:put, "/#{self.class.resource_name}/#{id}", to_request)
      end
      
      if response["response"]["errors"]
        message = response["response"]["errors"].map {|k,v| "#{k}: #{v}" }.join("\n")
        raise Solve360::SaveFailure, message
      else
        related_items.concat(related_items_to_add)
        self.related_items_to_add = []

        categories.concat(categories_to_add)
        self.categories_to_add = []

        response
      end

    end
    
    def new_record?
      self.id == nil
    end
    
    def to_request
      xml = "<request>"
      
      xml << map_human_fields.collect {|key, value| "<#{key}>#{CGI.escapeHTML(value.to_s)}</#{key}>"}.join("")
      
      if related_items_to_add.size > 0
        xml << "<relateditems><add>"

        related_items_to_add.each do |related_item|
          xml << %Q{<relatedto><id>#{related_item["id"]}</id></relatedto>}
        end

        xml << "</add></relateditems>"
      end

      if categories_to_add.size > 0
        xml << "<categories><add>"

        categories_to_add.each do |category|
          xml << %Q{<category>#{category["id"]}</category>}
        end

        xml << "</add></categories>"
      end
      
      xml << "<ownership>#{ownership}</ownership>"
      xml << "</request>"
      
      xml
    end
    
    def add_activity( type, fields = {} )
      post = {}
      post["parent"] = fields.delete(:parent) || id.to_s
      post["file"] = fields.delete(:file) if fields[:file]
      fields.each{ |key, val| post["data[#{key}]"] = val }

      uri = "#{HTTParty.normalize_base_uri(Config.config.url)}/#{self.class.resource_name}/#{type}"

      response = self.class.post(uri, :query => post, :basic_auth => self.class.auth_credentials)

      if response["response"]["errors"]
        message = response["response"]["errors"].map {|k,v| "#{k}: #{v}" }.join("\n")
        raise Solve360::SaveFailure, message
      else
        act = {}
        act["id"] = response["response"]["id"]
        act["parent"] = post["parent"]
        act["fields"] = fields

        # Prepend activity to beginning of list to match what we would get if
        # we reloaded the item from the server.
        self.activities = (activities || []).unshift(act)
        act
      end
    end

    def delete_activity( activity_id )
      # For now it the Solve360 API doesn't care if the activity type in the delete URL
      # matches the actual type of the activity we are deleting so hard coding to :task.
      type = :task

      uri = "#{HTTParty.normalize_base_uri(Config.config.url)}" +
                "/#{self.class.resource_name}/#{type}/#{activity_id}"

      response = self.class.delete(uri, :basic_auth => self.class.auth_credentials)

      if response["response"]["errors"]
        message = response["response"]["errors"].map {|k,v| "#{k}: #{v}" }.join("\n")
        raise Solve360::SaveFailure, message
      else
        act_idx = activities.index{|act| act["id"] == activity_id}
        activities.delete_at( act_idx ) if act_idx
      end
    end

    def add_note( note )
      add_activity(:note, details: note )
    end
    
    module ClassMethods
    
      # Map human map_human_fields to API fields
      # 
      # @param [Hash] human mapped fields
      # @example
      #   map_attributes("First Name" => "Steve", "Description" => "Web Developer")
      #   => {:firstname => "Steve", :custom12345 => "Web Developer"}
      # 
      # @return [Hash] API mapped attributes
      #
      def map_human_fields(fields)
        mapped_fields = {}

        field_mapping.each do |human, api|
          mapped_fields[api] = fields[human] if !fields[human].blank?
        end

        mapped_fields
      end
      
      # As ::map_api_fields but API -> human
      #
      # @param [Hash] API mapped attributes
      # @example
      #   map_attributes(:firstname => "Steve", :custom12345 => "Web Developer")
      #   => {"First Name" => "Steve", "Description" => "Web Developer"}
      #
      # @return [Hash] human mapped attributes
      def map_api_fields(fields)
        fields.stringify_keys!
        
        mapped_fields = {}

        field_mapping.each do |human, api|
          if fields[api].present? && fields[api]["__content__"].present?
            mapped_fields[human] = fields.delete(api)["__content__"]
          end
        end

        fields.each do |api_name, field|
          if field && field["label"].present?
            mapped_fields[ field["label"] ] = field["__content__"]
            fields.delete(api_name)
          end
        end
        
        mapped_fields
      end
      
      # Create a record in the API
      #
      # @param [Hash] field => value as configured in Item::fields
      def create(fields, options = {})
        new_record = self.new(fields)
        new_record.save
        new_record
      end
      
      # Find records
      # 
      # @param [Integer, Symbol] id of the record on the CRM or :all
      def find(id)
        if id == :all
          find_all
        else
          find_one(id)
        end
      end

      def search(search_by, value)
        find_all( filtermode: search_by, filtervalue: value )
      end

      def find_by_phone( phone )
        search(:byphone, phone)
      end

      def find_by_email( email )
        search(:byemail, email)
      end
      
      # Find a single record
      # 
      # @param [Integer] id of the record on the CRM
      def find_one(id)
        response = request(:get, "/#{resource_name}/#{id}")
        #puts response
        construct_record_from_singular(response)
      end
      
      # Find all records
      def find_all( params = {} )
        params[:layout] = 1
        response = request(:get, "/#{resource_name}/", "", params)
        #puts response
        construct_record_from_collection(response)
      end
      
      # Send an HTTP request
      # 
      # @param [Symbol, String] :get, :post, :put or :delete
      # @param [String] url of the resource 
      # @param [String, nil] optional string to send in request body
      def request(verb, uri, body = "", query = nil)
        send(verb, HTTParty.normalize_base_uri(Solve360::Config.config.url) + uri,
            :headers => {"Content-Type" => "application/xml", "Accepts" => "application/json"},
            :body => body,
            :query => query,
            :basic_auth => auth_credentials)
      end
      
      def construct_record_from_singular(response)
        response = response["response"]

        item = response["item"]
        item.symbolize_keys!

        item[:fields] = map_api_fields(item[:fields])

        related_items= response["relateditems"]["relatedto"] if response["relateditems"]
        item[:related_items] = related_items.is_a?(Array) ? related_items : [related_items]

        categories = response["categories"]["category"] if response["categories"]
        item[:categories] = categories.is_a?(Array) ? categories : [categories]

        item[:activities] = response["activities"].collect{|i| i[1]} if response["activities"]

        #puts "\n\nIn construct_record_from_singular:\n#{item.inspect}\n\n"

        record = new(item)
        #
        #if response["response"]["relateditems"]
        #  related_items = response["response"]["relateditems"]["relatedto"]
        #
        #  if related_items.kind_of?(Array)
        #    record.related_items.concat(related_items)
        #  else
        #    record.related_items = [related_items]
        #  end
        #end
        
        record
      end
      
      def construct_record_from_collection(response)
        response["response"].collect do |item|  
          item = item[1]
          if item.respond_to?(:keys)
            item[:fields] = map_api_fields(item)
            new item
          end
        end.compact
      end
      
      def resource_name
        self.name.to_s.demodulize.underscore.pluralize
      end

      def map_fields(&block)        
        @field_mapping.merge! yield
      end
      
      def field_mapping
        @field_mapping
      end

      def auth_credentials
        {:username => Solve360::Config.config.username, :password => Solve360::Config.config.token}
      end
    end
  end
end