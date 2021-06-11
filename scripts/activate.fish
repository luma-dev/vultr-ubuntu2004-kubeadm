set -l defs ( \
  terraform output -json host_v4_list \
  | jq \
  -r '
    . as $root
    | keys
    | .[]
    | . as $name
    | $name + "," + $root[$name]
  ' \
)

for def in $defs
  set -l name (echo $def | awk -F',' '{ print $1 }')
  set -l ipv4 (echo $def | awk -F',' '{ print $2 }')
  set -x $name $ipv4
end
