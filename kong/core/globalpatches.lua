return function(options)

  options = options or {}
  local meta = require "kong.meta"

  _G._KONG = {
    _NAME = meta._NAME,
    _VERSION = meta._VERSION
  }



  do

    if options.cli then
      ngx.IS_CLI = true
      
      
      -- disable the nginx exit method when running under the cli
      ngx.exit = function() end
      
      
      
      -- ngx.shared.DICT proxy
      -- https://github.com/bsm/fakengx/blob/master/fakengx.lua
      -- with minor fixes and addtions such as exptime
      --
      -- See https://github.com/openresty/resty-cli/pull/12
      -- for a definitive solution ot using shms in CLI
      local SharedDict = {}
      local function set(data, key, value)
        data[key] = {
          value = value,
          info = {expired = false}
        }
      end
      function SharedDict:new()
        return setmetatable({data = {}}, {__index = self})
      end
      function SharedDict:get(key)
        return self.data[key] and self.data[key].value, nil
      end
      function SharedDict:set(key, value)
        set(self.data, key, value)
        return true, nil, false
      end
      SharedDict.safe_set = SharedDict.set
      function SharedDict:add(key, value, exptime)
        if self.data[key] ~= nil then
          return false, "exists", false
        end

        if exptime then
          ngx.timer.at(exptime, function()
            self.data[key] = nil
          end)
        end

        set(self.data, key, value)
        return true, nil, false
      end
      function SharedDict:replace(key, value)
        if self.data[key] == nil then
          return false, "not found", false
        end
        set(self.data, key, value)
        return true, nil, false
      end
      function SharedDict:delete(key)
        self.data[key] = nil
        return true
      end
      function SharedDict:incr(key, value)
        if not self.data[key] then
          return nil, "not found"
        elseif type(self.data[key].value) ~= "number" then
          return nil, "not a number"
        end
        self.data[key].value = self.data[key].value + value
        return self.data[key].value, nil
      end
      function SharedDict:flush_all()
        for _, item in pairs(self.data) do
          item.info.expired = true
        end
      end
      function SharedDict:flush_expired(n)
        local data = self.data
        local flushed = 0

        for key, item in pairs(self.data) do
          if item.info.expired then
            data[key] = nil
            flushed = flushed + 1
            if n and flushed == n then
              break
            end
          end
        end
        self.data = data
        return flushed
      end
      function SharedDict:get_keys(n)
        n = n or 1024
        local i = 0
        local keys = {}
        for k in pairs(self.data) do
          keys[#keys+1] = k
          i = i + 1
          if n ~= 0 and i == n then
            break
          end
        end
        return keys
      end

      -- hack
      _G.ngx.shared = setmetatable({}, {
        __index = function(self, key)
          local shm = rawget(self, key)
          if not shm then
            shm = SharedDict:new()
            rawset(self, key, SharedDict:new())
          end
          return shm
        end
      })
    end
  
  end



  do -- patch luassert when running in the Busted test enviornment
    
    if options.rbusted then
      -- patch luassert's 'assert' to fix the 'third' argument problem
      -- see https://github.com/Olivine-Labs/luassert/pull/141
      local assert = require "luassert.assert"
      local assert_mt = getmetatable(assert)
      if assert_mt then
        assert_mt.__call = function(self, bool, message, level, ...)
          if not bool then
            local lvl = 2
            if type(level) == "number" then
              lvl = level + 1
            end
            error(message or "assertion failed!", lvl)
          end
          return bool, message, level, ...
        end
      end
    end

  end
  
  
  
  do -- randomseeding patch

    local randomseed = math.randomseed
    local seed

    --- Seeds the random generator, use with care.
    -- Once - properly - seeded, this method is replaced with a stub
    -- one. This is to enforce best-practises for seeding in ngx_lua,
    -- and prevents third-party modules from overriding our correct seed
    -- (many modules make a wrong usage of `math.randomseed()` by calling
    -- it multiple times or do not use unique seed for Nginx workers).
    --
    -- This patched method will create a unique seed per worker process,
    -- using a combination of both time and the worker's pid.
    -- luacheck: globals math
    _G.math.randomseed = function()
      if not seed then
        -- If we're in runtime nginx, we have multiple workers so we _only_
        -- accept seeding when in the 'init_worker' phase.
        -- That is because that phase is the earliest one before the
        -- workers have a chance to process business logic, and because
        -- if we'd do that in the 'init' phase, the Lua VM is not forked
        -- yet and all workers would end-up using the same seed.
        if not options.cli and ngx.get_phase() ~= "init_worker" then
          ngx.log(ngx.ERR, debug.traceback("math.randomseed() must be called in init_worker"))
        end

        seed = ngx.time() + ngx.worker.pid()
        ngx.log(ngx.DEBUG, "random seed: ", seed, " for worker nb ", ngx.worker.id(),
                           " (pid: ", ngx.worker.pid(), ")")
        randomseed(seed)
      else
        ngx.log(ngx.DEBUG, "attempt to seed random number generator, but ",
                           "already seeded with ", seed)
      end

      return seed
    end

  end



  do -- cosockets connect patch for dns resolution

    --- Patch the TCP connect method such that all connections will be resolved
    -- first by the internal DNS resolver. 
    -- STEP 1: load code that should not be using the patched versions
    require "resty.dns.resolver"  -- will cache TCP and UDP functions
    -- STEP 2: forward declaration of locals to hold stuff loaded AFTER patching
    local toip
    -- STEP 3: store original unpatched versions
    local old_tcp = ngx.socket.tcp
    -- STEP 4: patch globals
    _G.ngx.socket.tcp = function(...)
      local sock = old_tcp(...)
      local old_connect = sock.connect
      
      sock.connect = function(s, host, port, sock_opts)
        local target_ip, target_port = toip(host, port)
        if not target_ip then 
          return nil, "[toip() name lookup failed]:"..tostring(target_port)
        else
          -- need to do the extra check here: https://github.com/openresty/lua-nginx-module/issues/860
          if not sock_opts then
            return old_connect(s, target_ip, target_port)
          else
            return old_connect(s, target_ip, target_port, sock_opts)
          end
        end
      end
      return sock
    end
    -- STEP 5: load code that should be using the patched versions, if any (because of dependency chain)
    toip = require("dns.client").toip  -- this will load utils and penlight modules for example

  end



  do -- patch for LuaSocket tcp sockets, block usage in cli.

    if options.cli then
      local socket = require "socket"
      socket.tcp = function(...)
        error("should not be using this")
      end
    end
  
  end



  do -- patch cassandra driver to use the cosockets anyway, as we've patched them above already

    require("cassandra.socket")  --just pre-loading the module will do
  
  end
  

end