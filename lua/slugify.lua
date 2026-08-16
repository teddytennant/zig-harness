-- Example scripted tool. Host injects `args` and `cwd`.
local s = tostring((args and args.text) or ""):lower()
s = s:gsub("[^%w]+", "-"):gsub("^%-", ""):gsub("%-$", "")
print(s)
return s
