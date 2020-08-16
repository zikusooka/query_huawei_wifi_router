#!/bin/bash
# This script queries a Huawei LTE WiFi router (MiFi) to get detailed information such
# as signal strength, battery status, remaining data balance etc.
#
# Copyright (C) 2018-2019 Joseph Zikusooka.
#
# Find me on twitter @jzikusooka or email josephzik AT gmail.com

#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.


# Variables
CURL_CMD="/usr/bin/curl"
COOKIE_JAR_FILE=/tmp/cookie_jar.$$
CURL_OPTS="-L -s -S -m 60 -A 'Mozilla/5.0' -k -b $COOKIE_JAR_FILE -c $COOKIE_JAR_FILE"
IP_ADDRESS=$1
LOGIN_ADMIN_USER="$2"
LOGIN_ADMIN_PASSWORD="$3"
if [[ $OSTYPE == darwin* ]]; then
    LOGIN_ADMIN_PASSWORD_BASE64=$(printf "$(printf "$LOGIN_ADMIN_PASSWORD" | shasum -a 256 |  cut -d ' ' -f 1)" | base64 | tr -d '\n')
else
    LOGIN_ADMIN_PASSWORD_BASE64=$(printf "$(printf "$LOGIN_ADMIN_PASSWORD" | sha256sum |  cut -d ' ' -f 1)" | base64 | tr -d '\n');
fi
ACTION=$4
LOGIN_OUTPUT_FILE=/tmp/login_output.$$
HTTP_BROWSER_USERAGENT="Mozilla/5.0"
HTTP_BROWSER_COMMAND="$CURL_CMD $CURL_OPTS"
SMS_MESSAGE_RAW_OUTPUT_FILE=/tmp/router_sms_message
HOSTS_CONNECTED_OUTPUT_FILE=/tmp/router_wifi_connected_hosts
TERM=linux
export TERM


###############
#  FUNCTIONS  #
###############

# Usage
usage () {
if [[ "x$IP_ADDRESS" = "x" || "x$LOGIN_ADMIN_USER" = "x" || "x$LOGIN_ADMIN_PASSWORD" = "x" ]];
then
clear
cat <<EOT
Usage: ./$(basename $0) [IP_ADDRESS] [LOGIN_USER] [LOGIN_PASSWORD][TASK (Optional)]

  e.g. ./$(basename $0) 192.168.8.1 admin secret info_all


Tasks
-----
info_all
battery
data
users
sms_read
sms_send [NUMBER] [MESSAGE]
reboot

EOT
exit
fi
}

# See if you can reach the router
check_connectivity () {
PING_COUNT=3
PING_TIMEOUT=3
ping -c $PING_COUNT -W $PING_TIMEOUT $IP_ADDRESS > /dev/null 2>&1
REACHEABLE=$?
#
# Notify and quit when there's NO Internet
if [ "$REACHEABLE" != "0" ];
then
clear
logger -s -t $(basename $0) "The WiFi router at $IP_ADDRESS is not reacheable.
Please check that it is powered on and that you are using the correct IP address"
exit 255
fi
}

# CLI Calculator
calc(){ awk "BEGIN{ print $* }" ;}

server_session_token_info () {
HTTP_BROWSER_URL=http://$IP_ADDRESS
FIRST_GET_TO_STORE_COOKIE_SESSION=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/html/home.html)
LOGIN_SERVER_COOKIE=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/webserver/SesTokInfo | sed -ne '/<SesInfo>/s#\s*<[^>]*>\s*##gp')
LOGIN_SERVER_TOKEN=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/webserver/SesTokInfo | sed -ne '/<TokInfo>/s#\s*<[^>]*>\s*##gp')
ADMIN_USER_PASSWORD_TOKEN="${LOGIN_ADMIN_USER}${LOGIN_ADMIN_PASSWORD_BASE64}${LOGIN_SERVER_TOKEN}"
if [[ $OSTYPE == darwin* ]]; then
    ADMIN_USER_PASSWORD_TOKEN_BASE64=$(printf "$(printf "$ADMIN_USER_PASSWORD_TOKEN" | shasum -a 256 |  cut -d ' ' -f 1)" | base64 | tr -d '\n')
else
    ADMIN_USER_PASSWORD_TOKEN_BASE64=$(printf "$(printf "$ADMIN_USER_PASSWORD_TOKEN" | sha256sum |  cut -d ' ' -f 1)" | base64 | tr -d '\n')
fi
}

# Login
login () {
server_session_token_info

# Connect and Login
$HTTP_BROWSER_COMMAND -o $LOGIN_OUTPUT_FILE $HTTP_BROWSER_URL/api/user/login \
        -H "__RequestVerificationToken: $LOGIN_SERVER_TOKEN" \
        -H "Cookie: $LOGIN_SERVER_COOKIE" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Username>$LOGIN_ADMIN_USER</Username><Password>$ADMIN_USER_PASSWORD_TOKEN_BASE64</Password><password_type>4</password_type></request>"

# Get login response
LOGIN_RESPONSE=$(cat "$LOGIN_OUTPUT_FILE" | sed -ne '/<response>/s#\s*<[^>]*>\s*##gp')
# Remove temp mifi login output file
[[ -e $LOGIN_OUTPUT_FILE ]] && rm -f $LOGIN_OUTPUT_FILE
if [ "$LOGIN_RESPONSE" = "OK" ];
then
echo "Logged in to your WiFi router"

else
cat <<EOT
Error: Could not Log in to your Wifi router.  Possible reasons include:

a) The password you used '$LOGIN_ADMIN_PASSWORD' is incorrect
b) The username name you used '$LOGIN_ADMIN_USER' is incorrect
c) The IP address of '$IP_ADDRESS' is not reachable

Login response: <$LOGIN_RESPONSE>

EOT
exit 254
fi
}

# Device Info
device_information () {
information=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/information)
DEVICE_NAME=$(echo "$information" | grep '<DeviceName>' | sed -ne '/<DeviceName>/s#\s*<[^>]*>\s*##gp')
DEVICE_SERIAL=$(echo "$information" | grep '<SerialNumber>' | sed -ne '/<SerialNumber>/s#\s*<[^>]*>\s*##gp')
DEVICE_IMEI=$(echo "$information" | grep '<Imei>' | sed -ne '/<Imei>/s#\s*<[^>]*>\s*##gp')
DEVICE_IMSI=$(echo "$information" | grep '<Imsi>' | sed -ne '/<Imsi>/s#\s*<[^>]*>\s*##gp')
DEVICE_MAC1=$(echo "$information" | grep '<MacAddress1>' | sed -ne '/<MacAddress1>/s#\s*<[^>]*>\s*##gp')
DEVICE_CLASS=$(echo "$information" | grep '<Classify>' | sed -ne '/<Classify>/s#\s*<[^>]*>\s*##gp')
DEVICE_ICCID=$(echo "$information" | grep '<Iccid>' | sed -ne '/<Iccid>/s#\s*<[^>]*>\s*##gp')
}

# Sim Status
sim_status () {
DEVICE_SIM_LOCK_STATUS_CURRENT=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep 'simlockStatus' | sed -ne '/<simlockStatus>/s#\s*<[^>]*>\s*##gp')
if [ "$DEVICE_SIM_LOCK_STATUS_CURRENT" = "0" ];
then
DEVICE_SIM_LOCK_STATUS="Unlocked"
else
DEVICE_SIM_LOCK_STATUS="Locked"
fi
#DEVICE_SIM_STATUS_CURRENT=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep 'simlockStatus' | sed -ne '/<simlockStatus>/s#\s*<[^>]*>\s*##gp')
#
# Alternative for Sim state and Lock
#api/monitoring/converged-status
}

# Battery Status
battery_status () {
monitoring_status=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status)
BATTERY_STATUS_CURRENT=$(echo "$monitoring_status" | grep 'BatteryStatus' | sed -ne '/<BatteryStatus>/s#\s*<[^>]*>\s*##gp')
BATTERY_PERCENT=$(echo "$monitoring_status" | grep 'BatteryPercent' | sed -ne '/<BatteryPercent>/s#\s*<[^>]*>\s*##gp')
# Battery level descriptions
BATTERY_THRESHOLD_FULL=100
BATTERY_THRESHOLD_LOW=35
BATTERY_THRESHOLD_WARNING=25
BATTERY_THRESHOLD_CRITICAL=15
# Full
if [[ "$BATTERY_PERCENT" -eq "$BATTERY_THRESHOLD_FULL" ]];
then
BATTERY_LEVEL="Full"
# Low
elif [[ "$BATTERY_PERCENT" -le "$BATTERY_THRESHOLD_LOW" && "$BATTERY_PERCENT" -gt "$BATTERY_THRESHOLD_WARNING" ]];
then
BATTERY_LEVEL="Low "
# Warning
elif [[ "$BATTERY_PERCENT" -le "$BATTERY_THRESHOLD_WARNING" && "$BATTERY_PERCENT" -gt "$BATTERY_THRESHOLD_CRITICAL" ]];
then
BATTERY_LEVEL="Warning"
# Critical
elif [[ "$BATTERY_PERCENT" -le "$BATTERY_THRESHOLD_CRITICAL" ]];
then
BATTERY_LEVEL="Critical"
#
else
# Normal
BATTERY_LEVEL="Normal"
fi
# Set Battery status type
if [[ "$BATTERY_STATUS_CURRENT" = "1" ]];
then
BATTERY_STATUS="Charging"
else
BATTERY_STATUS="Not Charging"
fi
}

# WiFi status
wifi_status () {
monitoring_status=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status)
WIFI_CONNECTION_STATUS=$(echo "$monitoring_status" | grep 'WifiConnectionStatus' | sed -ne '/<BatteryPercent>/s#\s*<[^>]*>\s*##gp')
WIFI_CURRENT_USERS=$(echo "$monitoring_status" | grep 'CurrentWifiUser' | sed -ne '/<BatteryPercent>/s#\s*<[^>]*>\s*##gp')
}

# Devices connected to MiFi
wifi_connected_devices () {
host_list=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/wlan/host-list)
# Output type
case $1 in
hostname)
# Using hostname
echo "$host_list" | grep 'HostName' | sed -ne '/<BatteryPercent>/s#\s*<[^>]*>\s*##gp' > $HOSTS_CONNECTED_OUTPUT_FILE
;;
mac_address)
# Using mac address
echo "$host_list" | grep 'MacAddress' | sed -ne '/<BatteryPercent>/s#\s*<[^>]*>\s*##gp' > $HOSTS_CONNECTED_OUTPUT_FILE
;;
ip_address)
# Using IP address
echo "$host_list" | grep 'IpAddress' | sed -ne '/<BatteryPercent>/s#\s*<[^>]*>\s*##gp' > $HOSTS_CONNECTED_OUTPUT_FILE
;;
*)
# Using hostname
echo "$host_list" | grep 'HostName' | sed -ne '/<BatteryPercent>/s#\s*<[^>]*>\s*##gp' > $HOSTS_CONNECTED_OUTPUT_FILE
;;
esac
# Extract clients
HOSTS_CONNECTED=$(cat $HOSTS_CONNECTED_OUTPUT_FILE | while read LINE; do echo -e "\t\t\t\t $LINE" | sed "s: ::g"; done)
}

# Network Provider Info
network_provider_info () {
NETWORK_PROVIDER=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/net/current-plmn | grep 'FullName' | sed -ne '/<FullName>/s#\s*<[^>]*>\s*##gp')
MCC_MNC_CODE=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/net/current-plmn | grep 'Numeric' | sed -ne '/<Numeric>/s#\s*<[^>]*>\s*##gp')
NETWORK_CONNECTION_STATUS_CURRENT=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep 'ConnectionStatus' | sed -ne '/<ConnectionStatus>/s#\s*<[^>]*>\s*##gp')
# Define connection status
case $NETWORK_CONNECTION_STATUS_CURRENT in
7|11|14|37)
NETWORK_CONNECTION_STATUS="Network access not allowed"
;;
12|13)
NETWORK_CONNECTION_STATUS="Connection failed, roaming not allowed"
;;
201)
NETWORK_CONNECTION_STATUS="Connection failed, bandwidth exceeded"
;;
900)
NETWORK_CONNECTION_STATUS="Connecting"
;;
901)
NETWORK_CONNECTION_STATUS="Connected"
;;
902)
NETWORK_CONNECTION_STATUS="Disconnected"
;;
903)
NETWORK_CONNECTION_STATUS="Disconnecting"
;;
904)
NETWORK_CONNECTION_STATUS="Connection failed or disabled"
;;
*)
NETWORK_CONNECTION_STATUS="Connection failed, the profile is invalid"
;;
esac
}

# Signal Info
signal_info () {
CURRENT_SIGNAL_STRENGTH=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep 'SignalIcon' | sed -ne '/<SignalIcon>/s#\s*<[^>]*>\s*##gp')
# Signal bars
case $CURRENT_SIGNAL_STRENGTH in
5)
NUMBER_OF_BARS=$(printf "\u2581\u2582\u2583\u2584\u2585")
;;
4)
NUMBER_OF_BARS=$(printf "\u2581\u2582\u2583\u2584")
;;
3)
NUMBER_OF_BARS=$(printf "\u2581\u2582\u2583")
;;
2)
NUMBER_OF_BARS=$(printf "\u2581\u2582")
;;
1)
NUMBER_OF_BARS=$(printf "\u2581")
;;
*)
NUMBER_OF_BARS=$(printf "")
;;
esac
#
MAXIMUM_SIGNAL_STRENGTH=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep 'maxsignal' | sed -ne '/<maxsignal>/s#\s*<[^>]*>\s*##gp')
SIGNAL_PERCENT=$(calc "$CURRENT_SIGNAL_STRENGTH/$MAXIMUM_SIGNAL_STRENGTH"*100)%
NETWORK_CELL_ID=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/signal | grep 'cell_id' | sed -ne '/<cell_id>/s#\s*<[^>]*>\s*##gp')
#
# Current Network Type
CURRENT_NETWORK_TYPE=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep 'CurrentNetworkType' | sed -ne '/<CurrentNetworkType>/s#\s*<[^>]*>\s*##gp')
case $CURRENT_NETWORK_TYPE in
0)
NETWORK_TYPE="No Service"
;;
1)
NETWORK_TYPE="GSM"
;;
2)
NETWORK_TYPE="GPRS (2.5G)"
;;
3)
NETWORK_TYPE="EDGE (2.75G)"
;;
4)
NETWORK_TYPE="WCDMA (3G)"
;;
5)
NETWORK_TYPE="HSDPA (3G)"
;;
6)
NETWORK_TYPE="HSUPA (3G)"
;;
7)
NETWORK_TYPE="HSPA (3G)"
;;
8)
NETWORK_TYPE="TD-SCDMA (3G)"
;;
9)
NETWORK_TYPE="HSPA+ (4G)"
;;
10)
NETWORK_TYPE="EV-DO rev. 0"
;;
11)
NETWORK_TYPE="EV-DO rev. A"
;;
12)
NETWORK_TYPE="EV-DO rev. B"
;;
13)
NETWORK_TYPE="1xRTT"
;;
14)
NETWORK_TYPE="UMB"
;;
15)
NETWORK_TYPE="1xEVDV"
;;
16)
NETWORK_TYPE="3xRTT"
;;
17)
NETWORK_TYPE="HSPA+ 64QAM"
;;
18)
NETWORK_TYPE="HSPA+ MIMO"
;;
19)
NETWORK_TYPE="LTE (4G)"
;;
41)
NETWORK_TYPE="UMTS (3G)"
;;
44)
NETWORK_TYPE="HSPA (3G)"
;;
45)
NETWORK_TYPE="HSPA+ (3G)"
;;
46)
NETWORK_TYPE="DC-HSPA+ (3G)"
;;
64)
NETWORK_TYPE="HSPA (3G)"
;;
65)
NETWORK_TYPE="HSPA+ (3G)"
;;
101)
NETWORK_TYPE="LTE (4G)"
;;
esac
}

# WAN IP, Primary, Secondary DNS Addresses
ip_address_info () {
WAN_IP_ADDRESS=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep 'WanIPAddress' | sed -ne '/<WanIPAddress>/s#\s*<[^>]*>\s*##gp')
PRIMARY_DNS=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep 'PrimaryDns' | sed -ne '/<PrimaryDns>/s#\s*<[^>]*>\s*##gp')
SECONDARY_DNS=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep 'SecondaryDns' | sed -ne '/<SecondaryDns>/s#\s*<[^>]*>\s*##gp')
}

# Data Balance - Available
data_balance_available () {
DATA_BUNDLE=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/start_date | grep 'DataLimit' | sed -ne '/<DataLimit>/s#\s*<[^>]*>\s*##gp')
DATA_START_DAY=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/start_date | grep 'StartDay' | sed -ne '/<StartDay>/s#\s*<[^>]*>\s*##gp')
DATA_USED_DOWNLOAD=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/month_statistics | grep 'CurrentMonthDownload' | sed -ne '/<CurrentMonthDownload>/s#\s*<[^>]*>\s*##gp')
DATA_USED_UPLOAD=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/month_statistics | grep 'CurrentMonthUpload' | sed -ne '/<CurrentMonthUpload>/s#\s*<[^>]*>\s*##gp')
# Data Limit in Bytes
if [[ $DATA_BUNDLE =~ .*GB.* ]]; then
	DATA_LIMIT=$(calc $(echo "$DATA_BUNDLE" | sed "s/GB//")*1073741824)
elif [[ $DATA_BUNDLE =~ .*MB.* ]]; then
	DATA_LIMIT=$(calc $(echo "$DATA_BUNDLE" | sed "s/MB//")*1048576)
elif [[ $DATA_BUNDLE =~ .*KB.* ]]; then
	DATA_LIMIT=$(calc $(echo "$DATA_BUNDLE" | sed "s/KB//")*1024)
else
    DATA_LIMIT=1
fi

if [ "$DATA_LIMIT" -eq "0" ]; then
   DATA_LIMIT=1
fi
# Data left
DATA_USED=$(calc $DATA_USED_DOWNLOAD+$DATA_USED_UPLOAD)
DATA_REMAINING=$(calc $DATA_LIMIT-$DATA_USED)

DATA_REMAINING_GB=$(calc $DATA_REMAINING/1073741824 | xargs printf '%.2f')
DATA_REMAINING_MB=$(calc $DATA_REMAINING/1048576 | xargs printf '%.0f')
DATA_REMAINING_PERCENT=$(calc "$DATA_REMAINING/$DATA_LIMIT*100" | xargs printf '%.1f')
DATA_REMAINING_PERCENT0=$(calc "$DATA_REMAINING/$DATA_LIMIT*100" | xargs printf '%.0f')

# Data balance descriptions
DATA_BALANCE_THRESHOLD_UNUSED=100
DATA_BALANCE_THRESHOLD_LOW=35
DATA_BALANCE_THRESHOLD_WARNING=20
DATA_BALANCE_THRESHOLD_CRITICAL=10
DATA_BALANCE_THRESHOLD_USED_UP=0
# Unused
if [[ "$DATA_REMAINING_PERCENT0" -eq "$DATA_BALANCE_THRESHOLD_UNUSED" ]];
then
DATA_BALANCE_STATUS="Unused"
# Low
elif [[ "$DATA_REMAINING_PERCENT0" -le "$DATA_BALANCE_THRESHOLD_LOW" && "$DATA_REMAINING_PERCENT0" -gt "$DATA_BALANCE_THRESHOLD_WARNING" ]];
then
DATA_BALANCE_STATUS="Low "
# Warning
elif [[ "$DATA_REMAINING_PERCENT0" -le "$DATA_BALANCE_THRESHOLD_WARNING" && "$DATA_REMAINING_PERCENT0" -gt "$DATA_BALANCE_THRESHOLD_CRITICAL" ]];
then
DATA_BALANCE_STATUS="Warning"
# Critical
elif [[ "$DATA_REMAINING_PERCENT0" -le "$DATA_BALANCE_THRESHOLD_CRITICAL" && "$DATA_REMAINING_PERCENT0" -gt "$DATA_BALANCE_THRESHOLD_USED_UP" ]];
then
DATA_BALANCE_STATUS="Critical"
# Used Up
elif [[ "$DATA_REMAINING_PERCENT0" -eq "$DATA_BALANCE_THRESHOLD_USED_UP" ]];
then
DATA_BALANCE_STATUS="Used Up"
#
else
# Enough
DATA_BALANCE_STATUS="Enough"
fi
}

# SMS - Unread messages
sms_unread_count () {
SMS_COUNT_UNREAD=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/check-notifications | grep 'UnreadMessage' | sed -ne '/<UnreadMessage>/s#\s*<[^>]*>\s*##gp')
}

sms_count_local_inbox () {
SMS_COUNT_LOCAL_INBOX_UNREAD=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/sms/sms-count | grep 'LocalUnread' | sed -ne '/<LocalUnread>/s#\s*<[^>]*>\s*##gp')
SMS_COUNT_LOCAL_INBOX_ALL=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/sms/sms-count | grep 'LocalInbox' | sed -ne '/<LocalInbox>/s#\s*<[^>]*>\s*##gp')
}

# SMS - Read 1 SMS message
read_sms_message_one () {
SMS_MESSAGE_COUNT=1
server_session_token_info
#
$HTTP_BROWSER_COMMAND -o $SMS_MESSAGE_RAW_OUTPUT_FILE $HTTP_BROWSER_URL/api/sms/sms-list \
        -H "__RequestVerificationToken: $LOGIN_SERVER_TOKEN" \
        -H "Cookie: $LOGIN_SERVER_COOKIE" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><PageIndex>1</PageIndex><ReadCount>$SMS_MESSAGE_COUNT</ReadCount><BoxType>1</BoxType><SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>0</UnreadPreferred></request>"
# Extract SMS message
SMS_MESSAGE_INDEX=$(cat "$SMS_MESSAGE_RAW_OUTPUT_FILE" | sed -ne '/<Index>/s#\s*<[^>]*>\s*##gp')
SMS_MESSAGE_DATE=$(cat "$SMS_MESSAGE_RAW_OUTPUT_FILE" | sed -ne '/<Date>/s#\s*<[^>]*>\s*##gp')
SMS_MESSAGE_FROM=$(cat "$SMS_MESSAGE_RAW_OUTPUT_FILE" | sed -ne '/<Phone>/s#\s*<[^>]*>\s*##gp')
SMS_MESSAGE_BODY=$(cat "$SMS_MESSAGE_RAW_OUTPUT_FILE" | sed -ne '/<Content>/s#\s*<[^>]*>\s*##gp')
# Print message
clear
cat <<EOT
Index:          $SMS_MESSAGE_INDEX
Date:           $SMS_MESSAGE_DATE
From:           $SMS_MESSAGE_FROM
Body:           $SMS_MESSAGE_BODY
EOT

# Set SMS message to already-read status
server_session_token_info
$HTTP_BROWSER_COMMAND -o /dev/null $HTTP_BROWSER_URL/api/sms/set-read \
        -H "__RequestVerificationToken: $LOGIN_SERVER_TOKEN" \
        -H "Cookie: $LOGIN_SERVER_COOKIE" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Index>$SMS_MESSAGE_INDEX</Index></request>"
}

# SMS - Send message
send_sms_message () {
SMS_DATE_NOW=$(date +'%Y-%m-%d %T')
SMS_PHONE_RECIPIENT=$1
SMS_TEXT="$2"
SMS_LENGTH=${#SMS_TEXT}
# Print recipient number and message
cat <<EOF
Sending the following message to $SMS_PHONE_RECIPIENT: $SMS_TEXT

EOF
#
server_session_token_info
#
$HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/sms/send-sms \
        -H "__RequestVerificationToken: $LOGIN_SERVER_TOKEN" \
        -H "Cookie: $LOGIN_SERVER_COOKIE" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Index>-1</Index><Phones><Phone>$SMS_PHONE_RECIPIENT</Phone></Phones><Sca></Sca><Content>$SMS_TEXT</Content><Length>$SMS_LENGTH</Length><Reserved>1</Reserved><Date>$SMS_DATE_NOW</Date></request>"
}

# Reboot
reboot () {
server_session_token_info
#
echo "Rebooting MiFi router, please wait ..."
$HTTP_BROWSER_COMMAND -o /dev/null $HTTP_BROWSER_URL/api/device/control \
        -H "__RequestVerificationToken: $LOGIN_SERVER_TOKEN" \
        -H "Cookie: $LOGIN_SERVER_COOKIE" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Control>1</Control></request>"
}

# All information
all_available_information () {
device_information
sim_status
battery_status
wifi_status
wifi_connected_devices
network_provider_info
signal_info
ip_address_info
data_balance_available
sms_unread_count
sms_count_local_inbox
}

clean_up () {
# Remove temp cookie jar file
[[ -e $COOKIE_JAR_FILE ]] && rm -f $COOKIE_JAR_FILE
}



#################
#  MAIN SCRIPT  #
#################

usage

check_connectivity

login

case $ACTION in
info_all)
# Query all data
all_available_information
# Print info
clear
cat <<EOT
Device Name:                    Huawei $DEVICE_CLASS
Device Model:                   $DEVICE_NAME
Device Serial:                  $DEVICE_SERIAL
Device Imei:                    $DEVICE_IMEI
Device Imsi:                    $DEVICE_IMSI
Device Iccid:                   $DEVICE_ICCID
Sim Lock Status:                $DEVICE_SIM_LOCK_STATUS

Network Connection status:      $NETWORK_CONNECTION_STATUS
Network Provider:               $NETWORK_PROVIDER ($MCC_MNC_CODE)
Network Type:                   $NETWORK_TYPE
Network Signal strength:        $NUMBER_OF_BARS ($SIGNAL_PERCENT)
Network Cell Tower:             $NETWORK_CELL_ID

WAN IP Address:                 $WAN_IP_ADDRESS
Primary DNS Address:            $PRIMARY_DNS
Secondary DNS Address:          $SECONDARY_DNS

Data balance remaining:         ${DATA_REMAINING_MB}MB / ${DATA_REMAINING_GB}GB
Data balance remaining:         ${DATA_REMAINING_PERCENT}%
Data Started on:                $DATA_START_DAY $(date '+%B %Y')

Battery Charge:                 $BATTERY_PERCENT%
Battery Status:                 $BATTERY_STATUS

WiFi connected users:           $WIFI_CURRENT_USERS
$HOSTS_CONNECTED

New SMS Messages (Unread/All):  $SMS_COUNT_UNREAD ($SMS_COUNT_LOCAL_INBOX_UNREAD/$SMS_COUNT_LOCAL_INBOX_ALL)

EOT
;;

battery)
battery_status
clear
cat <<EOT
*******************************************************************************
$(date '+%A %d %B %Y')          $(date '+%-I:%M%p')
*******************************************************************************

Battery Level:                  $BATTERY_LEVEL

Battery Charge:                 $BATTERY_PERCENT%
Battery Status:                 $BATTERY_STATUS

EOT
;;

data)
data_balance_available
clear
cat <<EOT
*******************************************************************************
$(date '+%A %d %B %Y')          $(date '+%-I:%M%p')
*******************************************************************************

Data Status:                    $DATA_BALANCE_STATUS

Data balance remaining:         ${DATA_REMAINING_MB}MB / ${DATA_REMAINING_GB}GB
Data balance remaining:         ${DATA_REMAINING_PERCENT}%
Data Started on:                $DATA_START_DAY $(date '+%B %Y')

EOT
;;

users)
wifi_status
case $5 in
1)
wifi_connected_devices hostname
;;
2)
wifi_connected_devices mac_address
;;
3)
wifi_connected_devices ip_address
;;
*)
wifi_connected_devices
;;
esac

clear
cat <<EOT
*******************************************************************************
$(date '+%A %d %B %Y')          $(date '+%-I:%M%p')
*******************************************************************************

Number of users:                [$WIFI_CURRENT_USERS]
Device(s) online:
$HOSTS_CONNECTED

EOT
;;

sms_read)
read_sms_message_one
;;

sms_send)
send_sms_message "$5" "$6"
;;

reboot)
reboot
;;

*)
$0 $IP_ADDRESS $LOGIN_ADMIN_USER $LOGIN_ADMIN_PASSWORD info_all
;;

esac

# Clean up
clean_up
