require 'sinatra'
require 'json/ext' # required for .to_json
require 'mongo'

configure do
  db = Mongo::Client.new([ '127.0.0.1:27017' ], :database => 'leyline-sheet')
  sheets = db[:Sheets]
  set :mongo_db, db
  set :sheets, sheets

end

get '/' do
  'Hello world!'
end

get '/collections/?' do
  content_type :json
  settings.mongo_db.database.collection_names.to_json
end

helpers do
  # a helper method to turn a string ID
  # representation into a BSON::ObjectId
  def object_id val
    begin
      BSON::ObjectId.from_string(val)
    rescue BSON::ObjectId::Invalid
      nil
    end
  end

  def document_by_id id
    id = object_id(id) if String === id
    if id.nil?
      {}.to_json
    else
      document = settings.mongo_db.find(:_id => id).to_a.first
      (document || {}).to_json
    end
  end
end

# list all documents in the test collection
get '/documents/?' do
  content_type :json
  settings.sheets.find.to_a.to_json
end

# find a document by its ID
get '/document/:id/?' do
  content_type :json
  document_by_id(params[:id])
end

post '/new_document/?' do
  content_type :json
  db = settings.sheets
  result = db.insert_one params
  db.find(:_id => result.inserted_id).to_a.first.to_json
end

# update the document specified by :id, setting its
# contents to params, then return the full document
put '/update/:id/?' do
  content_type :json
  id = object_id(params[:id])
  settings.sheets.find(:_id => id).
      find_one_and_update('$set' => request.params)
  document_by_id(id)
end

# update the document specified by :id, setting just its
# name attribute to params[:name], then return the full
# document
put '/update_name/:id/?' do
  content_type :json
  id   = object_id(params[:id])
  name = params[:name]
  settings.sheets.find(:_id => id).
      find_one_and_update('$set' => {:name => name})
  document_by_id(id)
end

# delete the specified document and return success
delete '/remove/:id' do
  content_type :json
  db = settings.sheets
  id = object_id(params[:id])
  documents = db.find(:_id => id)
  if !documents.to_a.first.nil?
    documents.find_one_and_delete
    {:success => true}.to_json
  else
    {:success => false}.to_json
  end
end