#!/bin/bash

IFS="|" read -ra uids <<< "$weibo_uids" # 在这里添加需要抓取的uid

# 封装curl请求函数
function curl_retry {
    local url=$1
    local max_retry=$2
    local retry=0
    local result=""

    while [ $retry -lt $max_retry ] && [ -z "$result" ]; do
        sleep 1
        result=$(curl -s $url)
        retry=$((retry+1))
    done

    if [ -z "$result" ]; then
        echo "Failed to get data from $url after $max_retry retries, exiting..."
        exit 1
    fi

    echo $result
}

# 处理每个card
function process_card {
    local card=$1
    local tmp_file=$2
    local id=$(echo $card | jq -r '.mblog.id')
    local extend=$(curl_retry "https://m.weibo.cn/statuses/extend?id=$id" 5 | jq)
    card=$(echo $card | jq --argjson extend "$extend" '.mblog.extend = $extend')
    echo $card | jq -c '.' >> $tmp_file
}

# 处理所有card
function process_cards {
    local cards=$1
    local tmp_file=$2
    for card in $(echo "${cards}" | jq -r '.[] | @base64'); do
        card=$(echo ${card} | base64 --decode)
        process_card "$card" "$tmp_file"
    done
}

for uid in "${uids[@]}"; do
    # 获取最新的微博数据
    json=$(curl_retry "https://m.weibo.cn/api/container/getIndex?jumpfrom=weibocom&type=uid&value=$uid&containerid=107603$uid" 5)

    # 处理所有card
    tmp_file=$(mktemp)
    cards=$(echo $json | jq '.data.cards')
    process_cards "$cards" "$tmp_file"

    # 合并数据
    output_file="weibo_${uid}.json"
    if [ -f "$output_file" ]; then
        # 处理新数据，去重后保存到临时文件中
        tmp_file2=$(mktemp)
        while read -r card; do
            id=$(echo $card | jq -r '.mblog.id')
            if grep -q "\"id\":\"$id\"" "$output_file"; then
                echo "Deleting existing card with id $id"
                cat "$output_file" | jq -c "select(.mblog.id != \"$id\")" > "${output_file}.tmp"
                mv "${output_file}.tmp" "$output_file"
            fi
            echo "$card" >> $tmp_file2
        done < $tmp_file
        # 合并新数据和已有数据
        cat $tmp_file2 >> "$output_file"
        rm $tmp_file2
    else
        cat $tmp_file > "$output_file"
    fi

    # 按itemid倒序排列
    cat "$output_file" | jq -s -c 'sort_by(.mblog.id) | reverse[]' > "${output_file}.tmp"
    mv "${output_file}.tmp" "$output_file"
done
