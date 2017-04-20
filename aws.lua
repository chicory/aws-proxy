-- resty.aws

local cjson = require 'cjson'
local resty_hmac = require 'resty.hmac'
local resty_sha256 = require 'resty.sha256'
local str = require 'resty.string'
local ordered_pairs = require 'resty.ordered_pairs'
local _M = { _VERSION = '0.1.0' }

local function get_credentials ()
  local access_key = os.getenv('AWS_ACCESS_KEY_ID')
  local secret_key = os.getenv('AWS_SECRET_ACCESS_KEY')
  if access_key ~= nil and secret_key ~= nil then
    return {
      access_key = access_key,
      secret_key = secret_key
    }
  end

  local res = ngx.location.capture('/_meta-data/iam/security-credentials/')
  if res.status ~= ngx.HTTP_OK then
    return
  end

  res = ngx.location.capture('/_meta-data/iam/security-credentials/' .. res.body)
  if res.status ~= ngx.HTTP_OK then
    return
  end

  local creds = cjson.decode(res.body)
  if creds['Type'] ~= 'AWS-HMAC' or creds['Code'] ~= 'Success' then
    return
  end

  return {
    access_key = creds['AccessKeyId'],
    secret_key = creds['SecretAccessKey'],
    security_token = creds['Token']
  }
end

local function get_iso8601_basic(timestamp)
  return os.date('!%Y%m%dT%H%M%SZ', timestamp)
end

local function get_iso8601_basic_short(timestamp)
  return os.date('!%Y%m%d', timestamp)
end

local function get_derived_signing_key(keys, timestamp, region, service)
  local h = resty_hmac:new()
  k_date = h:digest('sha256', 'AWS4' .. keys['secret_key'], get_iso8601_basic_short(timestamp), true)
  k_region = h:digest('sha256', k_date, region, true)
  k_service = h:digest('sha256', k_region, service, true)
  return h:digest('sha256', k_service, 'aws4_request', true)
end

local function get_cred_scope(timestamp, region, service)
  return get_iso8601_basic_short(timestamp)
    .. '/' .. region
    .. '/' .. service
    .. '/aws4_request'
end

local function get_sha256_digest(s)
  local h = resty_sha256:new()
  h:update(s or '')
  return str.to_hex(h:final())
end

local function get_canonical_uri(uri)
  return uri
end

local function get_canonical_query_string(uri)
  return ''
end

local function get_canonical_headers()
  local headers = ngx.req.get_headers()
  local canonical_headers = ''
  for k, v in ordered_pairs(headers) do
    -- trim leading and trailing whitespace
    v = v:gsub("^%s*(.-)%s*$", "%1")
    canonical_headers = canonical_headers .. k:lower() .. ':' .. v .. '\n'

--    io.stderr:write("\nHEADER:\n")
--    io.stderr:write(k:lower() .. ':' .. v .. '\n')
  end
  return canonical_headers
end

local function get_signed_headers()
  local headers = ngx.req.get_headers()
  local signed_headers = ''
  for k, v in ordered_pairs(headers) do
    signed_headers = signed_headers .. k:lower() .. ';'
  end
  return signed_headers:sub(1, -2)
end

local function get_hashed_canonical_request(timestamp, host, uri)
  ngx.req.read_body()

  local request_body = ngx.req.get_body_data() or ''
  local digest = get_sha256_digest(request_body)

  ngx.req.set_header('x-amz-content-sha256', digest)

  if #request_body > 0 then
    ngx.req.set_header('content-length', #request_body)
  else
    ngx.req.set_header('content-length', nil)
  end

  local canonical_request =
    ngx.var.request_method .. '\n'
    .. get_canonical_uri(uri) .. '\n'
    .. get_canonical_query_string(uri) .. '\n'
    .. get_canonical_headers() .. '\n'
    .. get_signed_headers() .. '\n'
    .. digest

--  io.stderr:write("\nCANONICAL REQUEST:\n")
--  io.stderr:write(canonical_request)
--  io.stderr:write("\n\n")
--  io.stderr:write(ngx.req.get_body_data() or '')
--  io.stderr:write("\n\n")

  ngx.req.discard_body()
  return get_sha256_digest(canonical_request)
end

local function get_string_to_sign(timestamp, region, service, host, uri)
  return 'AWS4-HMAC-SHA256\n'
    .. get_iso8601_basic(timestamp) .. '\n'
    .. get_cred_scope(timestamp, region, service) .. '\n'
    .. get_hashed_canonical_request(timestamp, host, uri)
end

local function get_signature(derived_signing_key, string_to_sign)
  local h = resty_hmac:new()
  return h:digest('sha256', derived_signing_key, string_to_sign, false)
end

local function get_authorization(keys, timestamp, region, service, host, uri)
  local derived_signing_key = get_derived_signing_key(keys, timestamp, region, service)
  local string_to_sign = get_string_to_sign(timestamp, region, service, host, uri)
  local auth = 'AWS4-HMAC-SHA256 '
    .. 'Credential=' .. keys['access_key'] .. '/' .. get_cred_scope(timestamp, region, service)
    .. ', SignedHeaders=' .. get_signed_headers()
    .. ', Signature=' .. get_signature(derived_signing_key, string_to_sign)

  --  io.stderr:write("\nSTRING TO SIGN:\n")
  --  io.stderr:write(string_to_sign)
  --  io.stderr:write("\n")

  return auth
end

local function get_service_and_region(host)
  local patterns = {
    {'s3.amazonaws.com', 's3', 'us-east-1'},
    {'s3%-external%-1.amazonaws.com', 's3', 'us-east-1'},
    {'s3%-([a-z0-9-]+)%.amazonaws%.com', 's3', nil},
    {'search%-[^%.]+.([a-z0-9-]+).es.amazonaws.com', 'es', nil},
  }
  for i,data in ipairs(patterns) do
    local region = host:match(data[1])
    if region ~= nil and data[3] == nil then
      return data[2], region
    elseif region ~= nil then
      return data[2], data[3]
    end
  end
  return nil, nil
end

local function aws_set_headers(host, uri)
  ngx.req.set_header('host', host)
  ngx.req.set_header('x-amz-date', get_iso8601_basic(timestamp))

  local creds = get_credentials()
  local timestamp = tonumber(ngx.time())
  local service, region = get_service_and_region(host)
  local auth = get_authorization(creds, timestamp, region, service, host, uri)

  ngx.req.set_header('Authorization', auth)

  if creds['security_token'] ~= nil then
    ngx.req.set_header('x-amz-security-token', creds['security_token'])
  end
end

local function s3_set_headers(host, uri)

  aws_set_headers(host, uri)
end

_M.aws_set_headers = aws_set_headers
_M.s3_set_headers = s3_set_headers

return _M