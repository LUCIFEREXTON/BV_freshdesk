require 'httparty'
require 'json'
require 'freshdesk'
class Api::V1::Freshdesk::TicketController < ApplicationController
  include HTTParty
  include Freshdesk

  protect_from_forgery
  before_action :load_user_defaults
  before_action :check_user_defaults
  before_action :check_user_email
  before_action :httparty_default_setting
  rescue_from StandardError, :with => :catch_error
  rescue_from BlogVault::Error, :with => :catch_custom_error

  def index
    verify_fields(params, [:page_no, :per_page, :order_by])
    all_tickets_res = self.class.get("/tickets?email=#{@email}&order_by=#{params[:order_by]}&per_page=#{@tickets_per_request}&page=#{params[:page_no]}")
    validate_response(all_tickets_res)
    all_tickets_res = JSON.parse(all_tickets_res.body)
    open_tickets = all_tickets_res.select { |ticket| [2,3].include?(ticket["status"]) }
    close_tickets = all_tickets_res.select { |ticket| [4,5].include?(ticket["status"]) }
    all_tickets_res_body = {
      :open => open_tickets,
      :close => close_tickets
    }
    render json: all_tickets_res_body, status: 200
  end

  def init_settings
    body = {
      :per_page => @per_page,
      :route => Freshdesk.routes,
      :tickets_per_request => @tickets_per_request
    }
    render json: body, status: 200
  end

  def read
    verify_fields(params, [:id, :user_id])

    ticket_res = self.class.get("/tickets/#{params[:id]}")
    validate_response(ticket_res)
    ticket_res = JSON.parse(ticket_res.body)
    raise BlogVault::Error.new('This Ticket doesn\'t exists') unless (ticket_res["requester_id"] == params[:user_id])
		
    conversation_res = self.class.get("/tickets/#{params[:id]}/conversations")
    validate_response(conversation_res)
    conversation_res = JSON.parse(conversation_res.body)
		
    ticket_res["conversationList"] = conversation_res.select{|conversation| conversation['private'] == false}
    render json: ticket_res, status: 200
  end

  def new
    ticket_fields_res = fetch_ticket_fields
    ticket_fields_res = ticket_field_filter(ticket_fields_res)
    render json: ticket_fields_res, status: 200
  end

  def create
    required_fields = get_required_fields(fetch_ticket_fields)
    verify_fields(params, required_fields)
    contact_exists?
    body = required_field(params, [:attachments, :subject, :description, :custom_fields])
    body[:email] = @email
    body[:priority] = 1
    body[:status] = 2
    #body[:custom_fields] = {
 #     :cf_blog_uri => params["custom_fields"]["cf_blog_uri"]
 #   }	
    res = self.class.post('/tickets', {
      :body => body,
      :headers => {"Content-Type" => 'multipart/form-data'} }
    )
    validate_response(res)
    render json: res.body, status: res.code
  end

  def update
    verify_fields(params, [:id, :status])
    res = self.class.put("/tickets/#{params[:id]}",{:body => { status: params[:status]}.to_json(),:headers => {"Content-Type" => "application/json"}})
    validate_response(res)
    render json: res.body, status: res.code
  end

  def reply
    verify_fields(params, [:agent_id, :body, :id, :user_id])
    body = required_field(params, [:body, :user_id, :attachments])
    body[:private] = false
    if params[:agent_id] != "null"
      agent_res = self.class.get("/agents/#{params[:agent_id]}")
      validate_response(agent_res)
      agent_res = JSON.parse(agent_res.body)
      body[:notify_emails] =  [agent_res["contact"]["email"]]
    end
    res = self.class.post("/tickets/#{params[:id]}/notes",{
      :body => body,
      :headers => {"Content-Type" => 'multipart/form-data'} 
    })
    validate_response(res)
    render json: res.body, status: res.code
  end
	
  def blog_uri_list
    blog_uri = [
      "https://google.com", 
      "https://facebook.com",
      "https://youtube.com",
      "https://twitter.com",
      "https://amazon.com",
      "https://blogvault.net"
    ]
    body = {
      :blog_uri_list => blog_uri
    }
    render json: body, status: 200
  end

  private
	
  def httparty_default_setting
    self.class.base_uri Freshdesk.base_url
    self.class.headers :Authorization => Freshdesk.api_key
  end

  def required_field(obj, labels_list)
    res_body = Hash.new
    labels_list.each do |label| 
      if obj.has_key?(label)
	res_body[label] = obj[label]
      end
    end
    res_body
  end

  def verify_fields(obj, labels)
    missing_fields = []
    labels.each do |label|
      missing_fields << label unless obj.has_key?(label) || ( obj.has_key?(:custom_fields) && obj["custom_fields"].has_key?(label) )
    end
    raise BlogVault::Error.new("You have not sent the following required fields: #{missing_fields.join(',')}") unless missing_fields.empty?
  end

  def validate_response(res)
    if res.code != 200 && res.code != 201 
      res_body = JSON.parse(res.body)
      res_body["errors"].each do |error|
	if error["message"] == 'There is no contact matching the given email'
	  raise BlogVault::Error.new("You have no Tickets!!!")
	end
      end
      raise BlogVault::Error.new("Server Issue, Please Try Again...") 
    end
  end

  def check_user_defaults
    @per_page ||= 10
    @tickets_per_request ||= 100
    @tickets_per_request = @tickets_per_request <= 100 ? @tickets_per_request : 100
  end

  def check_user_email
    raise BlogVault::Error.new('Email passed is having value nil') if @email.nil?
    raise BlogVault::Error.new('Invalid Email format') if (@email =~ URI::MailTo::EMAIL_REGEXP).nil?
  end

  def catch_error(error)
    logger.error "#{error.class}- #{error.message} -#{error.backtrace}"
    render json: { message: 'Server Error' }, status: 400
  end

  def catch_custom_error(error)
    logger.error "#{error.class}- #{error.message} -#{error.backtrace}"
    render json: { message: error }, status: 400
  end
	
  def logger
    @logger ||= ActiveSupport::Logger.new("#{Rails.root.to_s}/log/freshdesk.log")
  end

  def fetch_ticket_fields
    ticket_fields_res = self.class.get("/ticket_fields")
    validate_response(ticket_fields_res)
    ticket_fields_res = JSON.parse(ticket_fields_res.body)
    discard_fields = [ "requester", "company" ]
    ticket_fields_res = ticket_fields_res.select { |ticket_field| ticket_field["customers_can_edit"] == true }
    ticket_fields_res = ticket_fields_res.select { |ticket_field| !discard_fields.include?(ticket_field["name"]) }
    ticket_fields_res
  end

  def get_required_fields(ticket_fields_res)
    required_fields = []
    ticket_fields_res.each do |ticket_field|
      required_fields << ticket_field["name"] if ticket_field["required_for_customers"]
    end
    required_fields
  end

  def ticket_field_filter(ticket_fields_res)
    ticket_fields_res.each do |ticket_field|
      case ticket_field["type"]
		
      when "default_requester"
	ticket_field["type"] = "text"
	ticket_field["input_type"] = "text"

      when "default_subject"
	ticket_field["type"] = "text"
	ticket_field["input_type"] = "text"

      when "default_ticket_type"
	ticket_field["type"] = "select"

      when "default_source"
	ticket_field["type"] = "select"

      when "default_status"
	ticket_field["type"] = "select"
	ticket_field["choices"] = ticket_field["choices"].each_with_object({}) do |(key, value), choice|
	  choice[value.last] = key
	end

      when "default_priority"
	ticket_field["type"] = "select"

      when "default_group"
	ticket_field["type"] = "select"

      when "default_agent"
	ticket_field["type"] = "select"

      when "default_description"
	ticket_field["type"] = "textarea"

      when "default_company"
	ticket_field["type"] = "select"

      when "custom_text"
	ticket_field["type"] = "text"
	ticket_field["input_type"] = "text"
		
      when "custom_checkbox"
	ticket_field["type"] = "checkbox"

      when "custom_dropdown"
	ticket_field["type"] = "select"

      when "nested_field"
	ticket_field["type"] = "nested_dropdown"

      when "custom_date"
	ticket_field["type"] = "date"
	ticket_field["input_type"] = "date"

      when "custom_number"
	ticket_field["type"] = "number"
	ticket_field["input_type"] = "text"

      when "custom_decimal"
	ticket_field["type"] = "decimal"
	ticket_field["input_type"] = "text"

      else
	ticket_field["type"] = "textarea"
      end
    end
    ticket_fields_res
  end

  def contact_exists?
    contact_res = self.class.get("/contacts?email=#{@email}")
    validate_response(contact_res)
    contact_res = JSON.parse(contact_res.body)
    if contact_res.empty?
      body = Hash.new
      body[:email] = @email
      body[:name] = @user_details[:name]
      body[:custom_fields] = @user_details.select { |key, value| key != :name }
      new_contact_res = self.class.post("/contacts", {
	:body => body.to_json(),
	:headers => {"Content-Type" => 'application/json'} 
      })
      validate_response(new_contact_res)
    end
  end
end
