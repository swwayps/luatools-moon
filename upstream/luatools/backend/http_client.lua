local m_http = require("http")
local config = require("config")

local http_client = {}

function http_client.get(url, options)
    options = options or {}
    options.timeout = options.timeout or config.HTTP_TIMEOUT_SECONDS
    return m_http.get(url, options)
end

function http_client.head(url, options)
    options = options or {}
    options.timeout = options.timeout or config.HTTP_TIMEOUT_SECONDS
    -- If Millennium m_http supports method override, we could use m_http.request, but let's assume m_http.head exists or use get with method = HEAD
    if type(m_http.head) == "function" then
        return m_http.head(url, options)
    end
    -- Fallback to standard request if head doesn't exist
    options.method = "HEAD"
    return m_http.get(url, options)
end

function http_client.post(url, options)
    options = options or {}
    options.timeout = options.timeout or config.HTTP_TIMEOUT_SECONDS
    local data = options.data
    options.data = nil
    return m_http.post(url, data, options)
end

return http_client
