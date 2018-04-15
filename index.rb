require 'sinatra'
require 'json/ext' # required for .to_json
require 'mongo'
require 'tempfile'
require 'roo'
require 'roo-xls'

enable :sessions

configure do
  set :mongo,  Mongo::Client.new([ '127.0.0.1:27017' ], :database => 'leyline-sheet')
end

get "/" do
  erb :form
end

get '/collections/?' do
  content_type :json
  settings.mongo.database.collection_names.to_json
end

get '/collection/:collection/?' do
  content_type :json
  collection = settings.mongo[params[:collection]]
  collection.find.to_a.to_json
end

get '/collection/:collection/:id/?' do
  content_type :json
  collection = settings.mongo[params[:collection]]
  find_document_by_id(params[:id],collection).to_json
end

get '/collection/:collection/:id/populate/:populate?' do
  content_type :json
  collection = settings.mongo[params[:collection]]
  unpopulated = find_document_by_id(params[:id],collection)

  params[:populate].split(',').each {|field_name|
    field_name = field_name.downcase
    collection_to_populate = settings.mongo[field_name + 's']
    id = unpopulated[field_name]
    unpopulated[field_name] = find_document_by_id(id, collection_to_populate)
  }

  return unpopulated.to_json
end

post '/collection/:collection/?' do
  content_type :json
  collection = settings.mongo[params[:collection]]
  result = collection.insert_one JSON.parse(request.body.read)
  find_document_by_id(result.inserted_id,collection).to_json
end

put '/collection/:collection/:id/?' do
  content_type :json
  collection = settings.mongo[params[:collection]]
  result = collection.find_one_and_update({:_id=>to_object_id(params[:id])},{'$set' => JSON.parse(request.body.read)})
  find_document_by_id(result[:_id],collection).to_json
end

delete '/collection/:collection/:id/?' do
  content_type :json
  collection = settings.mongo[params[:collection]]
  document = collection.find_one_and_delete(:_id=>to_object_id(params[:id]))

  if !document.nil?
    {:success => true}.to_json
  else
    {:success => false}.to_json
  end
end

post '/login' do
  content_type :json
  users = settings.mongo[:users]
  res = users.find(:name=>params[:name],:password=>params[:password]).to_a.first
  unless res.nil?
    session['userId'] = res['_id']
    return 200
  end
  return 403
end

helpers do
  def to_object_id(val)
    begin
      BSON::ObjectId.from_string(val)
    rescue BSON::ObjectId::Invalid
      nil
    end
  end

  def find_document_by_id (id,collection)
    id = to_object_id(id) if String === id
    res = nil
    unless id.nil?
      res = collection.find(:_id => id).to_a.first
    end
    return (res || {})
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

  heads_collection = settings.mongo[:heads]
  result = heads_collection.insert_one :content => head_content

  sheets_collection = settings.mongo[:sheets]
  result =  sheets_collection.insert_one({:head => result.inserted_id,:title => (@filename.sub! '.'+filetype.to_s, "") })
  find_document_by_id(result.inserted_id,sheets_collection).to_json
end

