require 'sinatra'
require 'json/ext' # required for .to_json
require 'mongo'
require 'tempfile'
require 'roo'
require 'roo-xls'
require "sinatra/cors"

set :allow_origin, "http://crazyrex.com:9528"
set :allow_methods, "HEAD,GET,PUT,POST,DELETE,OPTIONS"
set :allow_headers, "Authorization, Content-Type, Accept, X-User-Email, X-Auth-Token"
set :allow_credentials, "true"

configure do
  set :mongo,  Mongo::Client.new([ '127.0.0.1:27017' ], :database => 'leyline-sheet')
end

#enable :sessions
use Rack::Session::Cookie, :key => 'rack.session',
    :path => '/',
    :secret => 'your_secret'

before do
  response.headers['Access-Control-Allow-Origin'] = '*'
end

# options "*" do
#   response.headers["Allow"] = "HEAD,GET,PUT,POST,DELETE,OPTIONS"
#   response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, Accept, X-User-Email, X-Auth-Token"
#   response.headers["Access-Control-Allow-Origin"] = "http://crazyrex.com:9528"
#   response.headers["Access-Control-Allow-Credentials"] = "true"
#   200
# end

get "/upload" do
  erb :upload
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
  unless session['user_id'].nil? #已经登陆
    return {:success => true}.to_json
  end

  users = settings.mongo[:users]
  login_info =  JSON.parse(request.body.read)
  res = users.find(login_info).to_a.first

  unless res.nil? #匹配
    session['user_id'] = res['_id'].to_s #登陆用户id信息存入Session
    return {:success => true}.to_json
  end
  return 403 #access denied
end

get '/logout' do
  session.clear
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

  def get_current_user
    if session['user_id'].nil?
      return nil
    end
    users = settings.mongo[:users]
    return find_document_by_id(session['user_id'],users)
  end

  def get_user_row_by_sheet_id(sheet_id)
    current_user = get_current_user
    sheets = settings.mongo[:sheets]
    # query = {:_id => to_object_id(params[:sheet]),
    #          :rows => {:user => current_user[:_id]}}
    # db.getCollection('sheets').aggregate([{$match:{_id:ObjectId('5ad37c24ff301e203839e2d2')}}, {$unwind: "$rows"}, {$match:{"rows.user":ObjectId('5ad370a9ff301e27088619a1')}}])
    query =[     {"$match"=> {:_id=> to_object_id(sheet_id)}},
                 {"$unwind" => "$rows"},
                 {"$match"=> {"rows.user"=> current_user[:_id]}}
    ]
    sheet = sheets.aggregate(query)
    begin
      return sheet.first[:rows]
    rescue
      return {}
    end
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

  heads = settings.mongo[:heads]
  result = heads.insert_one :content => head_content

  sheets = settings.mongo[:sheets]
  result =  sheets.insert_one({:head => result.inserted_id,:title => (@filename.sub! '.'+filetype.to_s, ""),:rows => [] })
  find_document_by_id(result.inserted_id,sheets).to_json
end

get '/sheet/:sheet/row' do
  current_user = get_current_user
  if current_user.nil?
    return 403
  end
  get_user_row_by_sheet_id(params[:sheet]).to_json
end

post '/sheet/:sheet/row' do
  current_user = get_current_user
  if current_user.nil?
    return 403
  end

  sheets = settings.mongo[:sheets]
  new_row =  JSON.parse(request.body.read)
  current_user_id = get_current_user[:_id]
  new_row['user'] = current_user_id
  sheets.find_one_and_update(
      {:_id=>to_object_id(params[:sheet]) },
      {
          "$pull"=>{:rows=>{:user=>current_user_id}},
          # "$push"=>{:rows=>new_row}
      }
  )
  result = sheets.find_one_and_update(
      {:_id=>to_object_id(params[:sheet]) },
      {
          "$push"=>{:rows=>new_row}
      }
  )
  find_document_by_id(result[:_id],sheets).to_json

end