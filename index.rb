require 'sinatra'
require 'json/ext' # required for .to_json
require 'mongo'
require 'roo'
require 'roo-xls'
require 'tempfile'

configure do
  db = Mongo::Client.new([ '127.0.0.1:27017' ], :database => 'leyline-sheet')

  set :mongo_db, db
  set :sheets, db[:Sheets]
  set :heads, db[:Heads]
  set :users, db[:Users]

end

get "/" do
  erb :form
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
get '/sheets/?' do
  content_type :json
  settings.sheets.find.to_a.to_json
end

# find a document by its ID
get '/sheet/:id/?' do
  content_type :json
  document_by_id(params[:id])
end

post '/sheet/?' do
  content_type :json
  db = settings.sheets
  result = db.insert_one params
  db.find(:_id => result.inserted_id).to_a.first.to_json
end

# update the document specified by :id, setting its
# contents to params, then return the full document
put '/sheet/:id/?' do
  content_type :json
  id = object_id(params[:id])
  settings.sheets.find(:_id => id).
      find_one_and_update('$set' => request.params)
  document_by_id(id)
end

# update the document specified by :id, setting just its
# name attribute to params[:name], then return the full
# document
put '/sheet/:id/:name/?' do
  content_type :json
  id   = object_id(params[:id])
  name = params[:name]
  settings.sheets.find(:_id => id).
      find_one_and_update('$set' => {:name => name})
  document_by_id(id)
end

# delete the specified document and return success
delete '/sheet/:id' do
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

post '/sheet/init' do
    HEAD_ROW_NUM = 1
    @filename = params[:file][:filename]
    file = params[:file][:tempfile]
    filetype = File.extname(@filename) == '.xls' ? :xls : :xlsx
    raw = Roo::Spreadsheet.open(file.path, extension: filetype)

    sheet = raw.sheet(0)
    head_names = sheet.row(HEAD_ROW_NUM)
    head_content_type = sheet.row(HEAD_ROW_NUM+1)

    head_content = head_names.each_with_index.map{|head_name,index|{head_name=>head_content_type[index]}}.to_a

    heads_collection = settings.heads
    result = heads_collection.insert_one :content => head_content
    # heads_collection.find(:_id => result.inserted_id).to_a.first.to_json

    sheets_collection = settings.sheets
    result =  sheets_collection.insert_one({:head_id => result.inserted_id,:title => (@filename.sub! '.'+filetype.to_s, "") })
    sheets_collection.find(:_id => result.inserted_id).to_a.first.to_json
end