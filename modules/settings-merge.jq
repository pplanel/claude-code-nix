# Merges nix-managed keys into a settings.json (the input).
#   $new[0]   what nix sets now
#   $prev[0]  what nix set last time, so keys and permission entries it no
#             longer sets are taken back out
# Keys nix sets win. The permission lists are combined: entries added by hand
# stay, and nix's own entries are added once.
def lists: ["allow", "deny", "ask", "additionalDirectories"];
def dedupe: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
($prev[0] // {}) as $p
| $new[0] as $n
| reduce ((($p | keys) - ($n | keys)) - ["permissions"])[] as $k (.; del(.[$k]))
| . * ($n | del(.permissions))
| if ($n.permissions // $p.permissions) == null then . else
    .permissions = (
      (.permissions // {})
      | reduce ((((($p.permissions // {}) | keys) - (($n.permissions // {}) | keys)) - lists))[] as $k (.; del(.[$k]))
      | . * (($n.permissions // {}) | with_entries(select(.key as $k | lists | index($k) | not)))
    )
    | reduce lists[] as $k (.;
        ((.permissions[$k] // []) - ($p.permissions[$k] // []) + ($n.permissions[$k] // []) | dedupe) as $v
        | if $v == [] then del(.permissions[$k]) else .permissions[$k] = $v end)
    | if .permissions == {} then del(.permissions) else . end
  end
