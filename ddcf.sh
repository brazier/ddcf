#!/usr/bin/env bash

parent_path="${BASH_SOURCE[0]%/*}"

#Redirect stdout and stderr to jopurnalctl, tagging with info and error respectively
exec > >(systemd-cat -t "ddcf" -p info ) 2> >(systemd-cat -t "ddcf" -p err )

# Check if config file is passed as arg or if ddcf.conf exist in same folder as the script
if [[ -z "$1" ]]; then
  if ! source ${parent_path}/ddcf.conf; then
    echo '[Error] Missing configuration file ddcf.conf or invalid syntax!' >&2
    exit 1
  fi
else
  if ! source "$1"; then
    echo '[Error] Missing configuration file '$1' or invalid syntax!' >&2
    exit 1
  fi
fi

#Valid regex for ipv4
REIP='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])$'

# Get current ip
ip=$(curl -4 -s -X GET ${ip_check_url} --max-time 10)

# Check if ip returned and if valid
if [ -z "$ip" ]; then
  echo "[Error] Can not get external ip from ${ip_check_url}" >&2
  exit 1
fi
if ! [[ "$ip" =~ $REIP ]]; then
  echo "[Error] IP Address returned was invalid!" >&2
  echo "$ip"
  exit 1
fi

# Convert csv to array
IFS=',' read -d '' -ra dns_records <<<"$cf_dns_record,"
unset 'dns_records[${#dns_records[@]}-1]'
declare dns_records

#Run once per domain in $dns_records
for record in "${dns_records[@]}"; do
  cf_record_info=$(curl -sS "https://api.cloudflare.com/client/v4/zones/${cf_zone_id}/dns_records?type=A&name=${record}" \
      -X GET \
      -H "Authorization: Bearer $cf_zone_api_token" \
      -H "Content-Type: application/json")
  #if something went wrong
  if [[ ${cf_record_info} == *"\"success\":false"* ]]; then
      echo ${cf_record_info}
      echo "[Error] Can't get dns record info from Cloudflare API" >&2
      exit 1
    fi

    #Get ip and id from response
    cf_record_ip=$(echo "$cf_record_info" | jq -r '.result.[].content') #ip
    cf_record_id=$(echo "$cf_record_info" | jq -r '.result.[].id')

    #Check if ip in the records are diff from current
    if [[ $cf_record_ip != $ip ]]; then 
      #Update record
      update_dns_record=$(curl -sS "https://api.cloudflare.com/client/v4/zones/${cf_zone_id}/dns_records/$cf_record_id" \
        -X PATCH \
        -H "Authorization: Bearer $cf_zone_api_token" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"$record\",\"content\":\"$ip\",\"ttl\":$cf_ttl,\"proxied\":$cf_proxied}")
    #if something didnt go wrong
    if [[ ${update_dns_record} != *"\"success\":false"* ]]; then
        #Output message and notify if true
        update_msg="[$record] changed from $cf_record_ip to $ip"
        echo $update_msg
        if [[ "$notify_discord" == "true" ]]; then
          notify=$(curl -sS "$discord_webhook_url" \
          -H "Content-Type: application/json" \
          -d "{\"username\": \"$discord_username\", \"content\": \"$update_msg\"}")
        fi
        if [[ "$notify_ntfy" == "true" ]]; then
          notify=$(curl -sS "ntfy.sh/ntfy_topic" \
          -d "$update_msg")
        fi
    else 
      echo "${update_dns_record}"
      echo "[Error] Update failed" >&2
      exit 1
    fi
  else 
    echo "[$record] Nothing to do. $cf_record_ip = $ip"
  fi
done