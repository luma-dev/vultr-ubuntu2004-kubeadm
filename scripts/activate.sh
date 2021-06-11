defs=$( \
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

for def in ${defs[@]}; do
  name=$(echo $def | awk -F',' '{ print $1 }')
  ipv4=$(echo $def | awk -F',' '{ print $2 }')
  export $name=$ipv4
done
