-- node/xtea.lua
-- Re-exports the shared XTEA library from the node's perspective.
-- Placed here so node code can simply require("xtea") without path fiddling.
return require("/shared/xtea")
