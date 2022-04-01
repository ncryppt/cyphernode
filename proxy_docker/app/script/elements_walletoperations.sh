#!/bin/sh

. ./trace.sh
. ./sendtoelementsnode.sh

elements_spend() {
  trace "Entering elements_spend()..."

  local data
  local request=${1}
  local address=$(echo "${request}" | jq -r ".address")
  trace "[elements_spend] address=${address}"
  local assetid=$(echo "${request}" | jq -r ".assetId")
  trace "[elements_spend] assetId=${assetid}"
  local amount=$(echo "${request}" | jq -r ".amount" | awk '{ printf "%.8f", $0 }')
  trace "[elements_spend] amount=${amount}"
  local conf_target=$(echo "${request}" | jq ".confTarget")
  trace "[elements_spend] confTarget=${conf_target}"
  local replaceable=$(echo "${request}" | jq ".replaceable")
  trace "[elements_spend] replaceable=${replaceable}"
  local subtractfeefromamount=$(echo "${request}" | jq ".subtractfeefromamount")
  trace "[elements_spend] subtractfeefromamount=${subtractfeefromamount}"
  local response
  local id_inserted
  local tx_details
  local tx_raw_details
  local returncode

  if [ "${assetid}" = "null" ]; then
    response=$(send_to_elements_spender_node "{\"method\":\"sendtoaddress\",\"params\":[\"${address}\",${amount},\"\",\"\",${subtractfeefromamount},${replaceable},${conf_target}]}")
  else
    response=$(send_to_elements_spender_node "{\"method\":\"sendtoaddress\",\"params\":[\"${address}\",${amount},\"\",\"\",${subtractfeefromamount},${replaceable},${conf_target},\"UNSET\",\"${assetid}\"]}")
  fi

  returncode=$?
  trace_rc ${returncode}
  trace "[elements_spend] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local txid=$(echo "${response}" | jq -r ".result")
    trace "[elements_spend] txid=${txid}"

    # Let's get transaction details on the spending wallet so that we have fee information
    tx_details=$(elements_get_transaction ${txid} "spender")
    tx_raw_details=$(elements_get_rawtransaction ${txid} | tr -d '\n')

    # Amounts and fees are negative when spending so we absolute those fields
    local tx_hash=$(echo "${tx_raw_details}" | jq -r '.result.hash')
    local tx_ts_firstseen=$(echo "${tx_details}" | jq '.result.timereceived')
    local tx_amount=$(echo "${tx_details}" | jq '.result.details[0].amount | fabs' | awk '{ printf "%.8f", $0 }')
    local tx_size=$(echo "${tx_raw_details}" | jq '.result.size')
    local tx_vsize=$(echo "${tx_raw_details}" | jq '.result.vsize')
    local tx_replaceable=$(echo "${tx_details}" | jq -r '.result."bip125-replaceable"')
    tx_replaceable=$([ ${tx_replaceable} = "yes" ] && echo "true" || echo "false")
    local fees=$(echo "${tx_details}" | jq '.result.details[0].fee | fabs' | awk '{ printf "%.8f", $0 }')

    # We need to get the corresponding unblinded address to work around the elements gettransaction bug with blinded addresses
    local unblinded_address=$(elements_getaddressinfo "${address}" true | jq -r ".result.unconfidential")
    trace "[elements_spend] unblinded_address=${unblinded_address}"

    ########################################################################################################
    # Let's publish the event if needed
    local event_message
    event_message=$(echo "${request}" | jq -er ".eventMessage")
    if [ "$?" -ne "0" ]; then
      # event_message tag null, so there's no event_message
      trace "[elements_spend] event_message="
      event_message=
    else
      # There's an event message, let's publish it!

      if [ "${assetid}" = "null" ]; then
        trace "[elements_spend] mosquitto_pub -h broker -t elements_spend -m \"{\"txid\":\"${txid}\",\"address\":\"${address}\",\"unblinded_address\":\"${unblinded_address}\",\"amount\":${tx_amount},\"eventMessage\":\"${event_message}\"}\""
        response=$(mosquitto_pub -h broker -t elements_spend -m "{\"txid\":\"${txid}\",\"address\":\"${address}\",\"unblinded_address\":\"${unblinded_address}\",\"amount\":${tx_amount},\"eventMessage\":\"${event_message}\"}")
      else
        trace "[elements_spend] mosquitto_pub -h broker -t elements_spend -m \"{\"txid\":\"${txid}\",\"address\":\"${address}\",\"unblinded_address\":\"${unblinded_address}\",\"amount\":${tx_amount},\"assetId\":\"${assetid}\",\"eventMessage\":\"${event_message}\"}\""
        response=$(mosquitto_pub -h broker -t elements_spend -m "{\"txid\":\"${txid}\",\"address\":\"${address}\",\"unblinded_address\":\"${unblinded_address}\",\"amount\":${tx_amount},\"assetId\":\"${assetid}\",\"eventMessage\":\"${event_message}\"}")
      fi
      returncode=$?
      trace_rc ${returncode}
    fi
    ########################################################################################################

    # Let's insert the txid in our little DB -- then we'll already have it when receiving confirmation
    id_inserted=$(sql "INSERT INTO elements_tx (txid, hash, confirmations, timereceived, fee, size, vsize, is_replaceable)"\
" VALUES ('${txid}', '${tx_hash}', 0, ${tx_ts_firstseen}, ${fees}, ${tx_size}, ${tx_vsize}, ${tx_replaceable})"\
" RETURNING id" \
    "SELECT id FROM elements_tx WHERE txid='${txid}'")
    trace_rc $?
    sql "INSERT INTO elements_recipient (address, unblinded_address, amount, elements_tx_id, assetid) VALUES ('${address}', '${unblinded_address}', ${amount}, ${id_inserted}, '${assetid}')"\
" ON CONFLICT DO NOTHING"
    trace_rc $?

    data="{\"status\":\"accepted\""
    data="${data},\"txid\":\"${txid}\",\"hash\":\"${tx_hash}\",\"details\":{\"address\":\"${address}\",\"unblindedAddress\":\"${unblinded_address}\",\"amount\":${amount},\"assetId\":\"${assetid}\",\"firstseen\":${tx_ts_firstseen},\"size\":${tx_size},\"vsize\":${tx_vsize},\"replaceable\":${tx_replaceable},\"fee\":${fees},\"subtractfeefromamount\":${subtractfeefromamount}}}"
  else
    local message=$(echo "${response}" | jq -e ".error.message")
    data="{\"message\":${message}}"
  fi

  trace "[elements_spend] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_bumpfee() {
  trace "Entering elements_bumpfee()..."

  local request=${1}
  local txid=$(echo "${request}" | jq -r ".txid")
  trace "[elements_bumpfee] txid=${txid}"

  local confTarget
  local response
  local returncode

  # jq -e will have a return code of 1 if the supplied tag is null.
  confTarget=$(echo "${request}" | jq -e ".confTarget")
  if [ "$?" -ne "0" ]; then
    # confTarget tag null, so there's no confTarget
    trace "[elements_bumpfee] confTarget="
    response=$(send_to_elements_spender_node "{\"method\":\"bumpfee\",\"params\":[\"${txid}\"]}")
    returncode=$?
  else
    trace "[elements_bumpfee] confTarget=${confTarget}"
    response=$(send_to_elements_spender_node "{\"method\":\"bumpfee\",\"params\":[\"${txid}\",{\"confTarget\":${confTarget}}]}")
    returncode=$?
  fi

  trace_rc ${returncode}
  trace "[elements_bumpfee] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    trace "[elements_bumpfee] error!"
  else
    trace "[elements_bumpfee] success!"
  fi

  echo "${response}"

  return ${returncode}
}

elements_get_txns_spending() {
  trace "Entering elements_get_txns_spending()... with count: $1 , skip: $2"
  local count="$1"
  local skip="$2"
  local response
  local data="{\"method\":\"listtransactions\",\"params\":[\"*\",${count:-10},${skip:-0}]}"
  response=$(send_to_elements_spender_node "${data}")
  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_get_txns_spending] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local txns=$(echo ${response} | jq -rc ".result")
    trace "[elements_get_txns_spending] txns=${txns}"

    data="{\"txns\":${txns}}"
  else
    trace "[elements_get_txns_spending] Coudn't get txns!"
    data=""
  fi

  trace "[elements_get_txns_spending] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_getbalance() {
  trace "Entering elements_getbalance()..."

  local response
  local data='{"method":"getbalance"}'
  response=$(send_to_elements_spender_node "${data}")
  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_getbalance] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local balance=$(echo ${response} | jq ".result")
    trace "[elements_getbalance] balance=${balance}"

    data="{\"balance\":${balance}}"
  else
    trace "[elements_getbalance] Coudn't get balance!"
    data=""
  fi

  trace "[elements_getbalance] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_getbalances() {
  trace "Entering elements_getbalances()..."

  local response
  local data='{"method":"getbalances"}'
  response=$(send_to_elements_spender_node "${data}")
  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_getbalances] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local balances=$(echo ${response} | jq ".result")
    trace "[elements_getbalances] balances=${balances}"

    data="{\"balances\":${balances}}"
  else
    trace "[elements_getbalances] Couldn't get balances!"
    data=""
  fi

  trace "[elements_getbalances] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_getbalancebyxpublabel() {
  trace "Entering elements_getbalancebyxpublabel()..."

  local label=${1}
  trace "[elements_getbalancebyxpublabel] label=${label}"
  local xpub

  xpub=$(sql "SELECT pub32 FROM elements_watching_by_pub32 WHERE label='${label}'")
  trace "[elements_getbalancebyxpublabel] xpub=${xpub}"

  elements_getbalancebyxpub ${xpub} "elements_getbalancebyxpublabel"
  returncode=$?

  return ${returncode}
}

elements_getbalancebyxpub() {
  trace "Entering elements_getbalancebyxpub()..."

  # ./bitcoin-cli -rpcwallet=xpubwatching01.dat listunspent 0 9999999 "$(./bitcoin-cli -rpcwallet=xpubwatching01.dat getaddressesbylabel upub5GtUcgGed1aGH4HKQ3vMYrsmLXwmHhS1AeX33ZvDgZiyvkGhNTvGd2TA5Lr4v239Fzjj4ZY48t6wTtXUy2yRgapf37QHgt6KWEZ6bgsCLpb | jq "keys" | tr -d '\n ')" | jq "[.[].amount] | add"

  local xpub=${1}
  trace "[elements_getbalancebyxpub] xpub=${xpub}"

  # If called from getbalancebyxpublabel, set the correct event for response
  local event=${2:-"elements_getbalancebyxpub"}
  trace "[elements_getbalancebyxpub] event=${event}"
  local addresses
  local balance
  local data
  local returncode

  # addresses=$(./bitcoin-cli -rpcwallet=xpubwatching01.dat getaddressesbylabel upub5GtUcgGed1aGH4HKQ3vMYrsmLXwmHhS1AeX33ZvDgZiyvkGhNTvGd2TA5Lr4v239Fzjj4ZY48t6wTtXUy2yRgapf37QHgt6KWEZ6bgsCLpb | jq "keys" | tr -d '\n ')
  data="{\"method\":\"getaddressesbylabel\",\"params\":[\"${xpub}\"]}"
  trace "[elements_getbalancebyxpub] data=${data}"
  addresses=$(send_to_xpub_elements_watcher_wallet ${data} | jq ".result | keys" | tr -d '\n ')
  # ./bitcoin-cli -rpcwallet=xpubwatching01.dat listunspent 0 9999999 "$addresses" | jq "[.[].amount] | add"
  data="{\"method\":\"listunspent\",\"params\":[0,9999999,${addresses}]}"
  trace "[elements_getbalancebyxpub] data=${data}"
  balance=$(send_to_xpub_elements_watcher_wallet ${data} | jq "[.result[].amount // 0 ] | add | . * 100000000 | trunc | . / 100000000")
  returncode=$?
  trace_rc ${returncode}
  trace "[elements_getbalancebyxpub] balance=${balance}"

  data="{\"event\":\"${event}\",\"xpub\":\"${xpub}\",\"balance\":${balance:-0}}"

  echo "${data}"

  return "${returncode}"
}

elements_getnewaddress() {
  trace "Entering elements_getnewaddress()..."

  local address_type=${1}
  trace "[elements_getnewaddress] address_type=${address_type}"

  local label=${2}
  trace "[elements_getnewaddress] label=${label}"

  local response
  local jqop
  local addedfieldstoresponse
  local data='{"method":"getnewaddress"}'
  if [ -n "${address_type}" ] || [ -n "${label}" ]; then
    jqop='. += {"params":{}}'
    if [ -n "${label}" ]; then
      jqop=${jqop}' | .params += {"label":"'${label}'"}'
      addedfieldstoresponse=' | . += {"label":"'${label}'"}'
    fi
    if [ -n "${address_type}" ]; then
      jqop=${jqop}' | .params += {"address_type":"'${address_type}'"}'
      addedfieldstoresponse=' | . += {"address_type":"'${address_type}'"}'
    fi
    trace "[elements_getnewaddress] jqop=${jqop}"
    trace "[elements_getnewaddress] addedfieldstoresponse=${addedfieldstoresponse}"

    data=$(echo "${data}" | jq -rc "${jqop}")
  fi
  trace "[elements_getnewaddress] data=${data}"

  response=$(send_to_elements_spender_node "${data}")
  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_getnewaddress] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local address=$(echo ${response} | jq ".result")
    trace "[elements_getnewaddress] address=${address}"

    data='{"address":'${address}'}'
    if [ -n "${jqop}" ]; then
      data=$(echo "${data}" | jq -rc ".${addedfieldstoresponse}")
      trace "[elements_getnewaddress] data=${data}"
    fi
  else
    trace "[elements_getnewaddress] Coudn't get a new address!"
    data=""
  fi

  trace "[elements_getnewaddress] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_create_wallet() {
  trace "[Entering elements_create_wallet()]"

  local walletname=${1}

  local rpcstring="{\"method\":\"createwallet\",\"params\":[\"${walletname}\",true]}"
  trace "[elements_create_wallet] rpcstring=${rpcstring}"

  local result
  result=$(send_to_elements_watcher_node ${rpcstring})
  local returncode=$?

  echo "${result}"

  return ${returncode}
}

elements_getwalletinfo() {
  trace "Entering elements_getwalletinfo()..."

  local data='{"method":"getwalletinfo"}'
  send_to_elements_spender_node "${data}" | jq ".result"
  return $?
}
