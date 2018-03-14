#!/bin/bash

#==================================================================================================================
#                                  Redis in K8s
#   1. 哨兵模式
#       1. MASTER = true
#           此节点可能会变成slave,但是其一开始是master,所以有一个循环,先循环一定次数来查找哨兵,如果没找到就启动自身
#       2. SLAVE = true
#           通过哨兵节点来查询主节点的信息,一旦找到就启动
#       3. SENTINEL = true
#           机制和slave一样
#
#
#   2. 集群(主从)模式
#       1. CLUSTER = true
#           启动一个多节点的redis服务,各个节点之间没有联系
#       2. CLUSTER_CTRL = true
#           将之前的节点拼接成一个集群
#      集群模式的说明:
#      集群普通节点的pod数量 必须 大于等于 (集群每个主节点的副本数*3 + 3)
#      如果想让集群外访问,只需要在yaml里面配置就可以了,不需要再来修改 shell 脚本
#
#
#==================================================================================================================


function echo_warn(){
    echo -e "\033[33m$1\033[0m"
}

function echo_info(){
    echo -e "\033[36m$1\033[0m"
}

function echo_error(){
    echo -e "\033[31m$1\033[0m"
}

function log_info(){
    time=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[36m$time  -  $1\033[0m"
}

function log_warn(){
    time=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[33m$time  - [WARNNING] $1\033[0m"
}

function log_error(){
    time=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[31m$time  - [ERROR] $1\033[0m"
}


function ip_array_length(){
    ips=$(nslookup $CLUSTER_SVC | grep 'Address' |awk '{print $3}')
    index=0
    for ip in $ips ;
    do
        let index++
    done
    echo $index
}

# 获取指定statefulset 下的副本数
function get_replicas(){
    replicas=$(curl -s ${API_SERVER_ADDR}/apis/apps/v1/namespaces/default/statefulsets/$1 | jq ".spec.replicas")
    echo $replicas
}

# 等待指定的statefulset 下的所有的pod启动完毕
function wait_all_pod_ready(){
    while true ; do
        ready_ip_length=$(ip_array_length) 
        replicas=$(get_replicas $1)   

        echo_info ""
        echo_info "\t\t\tIP_ARRAY_LENGTH  : $ready_ip_length     "
        echo_info "\t\t\tREPLICAS  : $replicas     "
        echo_info ""

        if test $ready_ip_length == $replicas ; then
            log_info "[OK] Pod Ready!!!"
            break
        else
            sleep 10
        fi  
    done
}

# 保存ip和pod名字的对应关系
function save_relation(){
    file=$1
    REPLICAS=$(get_replicas "sts-redis-cluster")
    rm -f /data/redis/cluster-$file.ip
    index=0
    while test $index -lt $REPLICAS ; do
        curl -s ${API_SERVER_ADDR}/api/v1/namespaces/default/pods/sts-redis-cluster-$index | jq ".status.podIP"  >> /data/redis/cluster-$file.ip 
        let index++
    done
    sed -i "s/\"//g" /data/redis/cluster-$file.ip
}


# 哨兵模式 master节点启动流程代码
function master_launcher(){

    echo_info "+--------------------------------------------------------------------+"
    echo_info "|                                                                    |"
    echo_info "|\t\t\tMaster Port  : $MASTER_PORT     "
    echo_info "|\t\t\tSentinel HOST: $SENTINEL_HOST   "
    echo_info "|\t\t\tSentinel Port: $SENTINEL_PORT   "
    echo_info "|                                                                    |"
    echo_info "+--------------------------------------------------------------------+"

    if test -f "/config/redis/slave.conf" ; then
        cp /config/redis/slave.conf /data/redis/slave.conf
    else
        log_error "Sorry , I cant find file -> /config/redis/slave.conf"
    fi

    if test -f "/config/redis/master.conf" ; then
        cp /config/redis/master.conf /data/redis/master.conf
    else
        log_error "Sorry , I cant find file -> /config/redis/master.conf"
    fi

    # 循环10次
    guard=0
    while test $guard -lt 10 ; do
        SENTINEL_IP=$(nslookup $SENTINEL_HOST | grep 'Address' | awk '{print $3}')
        MASTER_IP=$(redis-cli -h $SENTINEL_IP -p $SENTINEL_PORT --csv SENTINEL get-master-addr-by-name mymaster | tr ',' ' ' | cut -d' ' -f1)
        if [[ -n $MASTER_IP && $MASTER_IP != "ERROR" ]] ; then
            MASTER_IP="${MASTER_IP//\"}"
            # 通过哨兵找到master，验证master是否正确
            redis-cli -h $MASTER_IP -p $MASTER_PORT INFO
            if test "$?" == "0" ; then
                sed -i "s/%master-ip%/$MASTER_IP/" /data/redis/slave.conf
                sed -i "s/%master-port%/$MASTER_PORT/" /data/redis/slave.conf
                PERSISTENT_PATH="/data/redis"
                sed -i "s|%persistent_path%|${PERSISTENT_PATH}|" /data/redis/slave.conf
                THIS_IP=$(hostname -i)
                echo "slave-announce-ip $THIS_IP" >> /data/redis/slave.conf
                echo "slave-announce-port $MASTER_PORT" >> /data/redis/slave.conf
                echo "logfile /data/redis/redis.log" >> /data/redis/slave.conf
                redis-server /data/redis/slave.conf --protected-mode no
                break
            else
                log_error "Can not connect to Master . Waiting...."
            fi
        fi
        let guard++
        # 如果循环了多次，都没有找到，那么就放弃啦，再来一轮寻找
        if test $guard -ge 10 ; then
            log_info "Starting master ...."
            redis-server /data/redis/master.conf --protected-mode no
            break
        fi
        sleep 2
    done
}

# 哨兵模式 slave节点启动流程代码
function slave_launcher(){

    echo_info "+--------------------------------------------------------------------+"
    echo_info "|                                                                    |"
    echo_info "|\t\t\tMaster Host  : $MASTER_HOST     "
    echo_info "|\t\t\tMaster Port  : $MASTER_PORT     "
    echo_info "|\t\t\tSentinel HOST: $SENTINEL_HOST   "
    echo_info "|\t\t\tSentinel Port: $SENTINEL_PORT   "
    echo_info "|                                                                    |"
    echo_info "+--------------------------------------------------------------------+"

    if test -f "/config/redis/slave.conf" ; then
        cp /config/redis/slave.conf /data/redis/slave.conf
    else
        log_error "Sorry , I cant find file -> /config/redis/slave.conf"
    fi


    while true; do
        SENTINEL_IP=$(nslookup ${SENTINEL_HOST} | grep 'Address' | awk '{print $3}')
        MASTER_IP=$(redis-cli -h ${SENTINEL_IP} -p ${SENTINEL_PORT} --csv SENTINEL get-master-addr-by-name mymaster | tr ',' ' ' | cut -d' ' -f1)
        if [[ -n ${MASTER_IP} ]] && [[ ${MASTER_IP} != "ERROR" ]] ; then
            MASTER_IP="${MASTER_IP//\"}"
        else
            sleep 2
            continue
        fi

        # 先从sentinel节点查找主节点信息，如果实在没有就直接从master节点找
        redis-cli -h ${MASTER_IP} -p ${MASTER_PORT} INFO
        if [[ "$?" == "0" ]]; then
            break
        fi

        log_error "Can not connect to Master .  Waiting..."
        sleep 5
    done

    THIS_IP=$(hostname -i)

    sed -i "s/%master-ip%/${MASTER_IP}/" /data/redis/slave.conf
    sed -i "s/%master-port%/${MASTER_PORT}/" /data/redis/slave.conf
    PERSISTENT_PATH="/data/redis/slave"
    sed -i "s|%persistent_path%|${PERSISTENT_PATH}|" /data/redis/slave.conf

    echo "slave-announce-ip ${THIS_IP}" >> /data/redis/slave.conf
    echo "slave-announce-port $MASTER_PORT" >> /data/redis/slave.conf
    echo "logfile /data/redis/redis.log" >> /data/redis/slave.conf

    redis-server  /data/redis/slave.conf --protected-mode no
}

# 哨兵模式 哨兵节点启动流程代码
function sentinel_launcher(){

    echo_info "+--------------------------------------------------------------------+"
    echo_info "|                                                                    |"
    echo_info "|\t\t\tMaster Host  : $MASTER_HOST     "
    echo_info "|\t\t\tMaster Port  : $MASTER_PORT     "
    echo_info "|\t\t\tSentinel SVC : $SENTINEL_SVC    "
    echo_info "|\t\t\tSentinel Port: $SENTINEL_PORT   "
    echo_info "|                                                                    |"
    echo_info "+--------------------------------------------------------------------+"

    MASTER_IP=""
    while true; do
        index=0
        while true; do
            let index++
            IP_ARRAY=$(nslookup $SENTINEL_SVC | grep 'Address' |awk '{print $3}' )
            for IP in $IP_ARRAY ;
            do
                MASTER_IP=$(redis-cli -h ${IP} -p ${SENTINEL_PORT} --csv SENTINEL get-master-addr-by-name mymaster | tr ',' ' ' | cut -d' ' -f1)
                if [[ -n ${MASTER_IP} &&  ${MASTER_IP} != "ERROR" ]] ; then
                    MASTER_IP="${MASTER_IP//\"}"
                fi
                redis-cli -h ${MASTER_IP} -p ${MASTER_PORT} INFO
                if test "$?" == "0" ; then
                    break 3
                fi
                log_error "Sentinel IP:${IP}  Connecting to master failed.  Waiting..."
            done
            if test $index -ge 10 ; then
                log_info "Could not find the Sentinel ,Try to connenct the master directly!..."
                MASTER_IP=$(nslookup $MASTER_HOST | grep 'Address' | awk '{print $3}')
                redis-cli -h ${MASTER_IP} -p ${MASTER_PORT} INFO
                if test "$?" == "0" ; then
                    break 2
                else
                    index=0
                fi
                log_error "Sentinel IP:${IP}  Master IP: ${MASTER_IP}  Connecting to master failed.  Waiting..."
            fi
        done
    done

    log_info "Master: $MASTER_IP"

    sentinel_conf=/data/redis/sentinel.conf

    echo "port $SENTINEL_PORT" >> ${sentinel_conf}
    echo "sentinel monitor mymaster ${MASTER_IP} ${MASTER_PORT} 2" >> ${sentinel_conf}
    echo "sentinel down-after-milliseconds mymaster 30000" >> ${sentinel_conf}
    echo "sentinel failover-timeout mymaster 180000" >> ${sentinel_conf}
    echo "sentinel parallel-syncs mymaster 1" >> ${sentinel_conf}
    echo "bind $(hostname -i) 127.0.0.1" >> ${sentinel_conf}
    echo "logfile /data/redis/redis.log" >> ${sentinel_conf}

    redis-sentinel ${sentinel_conf} --protected-mode no
}

# 集群模式 普通集群节点启动流程代码
function cluster_launcher(){
    # 等待并保存ip和pod的关系
    wait_all_pod_ready "sts-redis-cluster"
    save_relation "new"

    # 如果有旧的关系文件,那么就对nodes.conf进行替换
    
    if test -f /data/redis/cluster-old.ip ; then
        if test -f "/data/redis/nodes.conf" ; then 
            
            echo_info "+-------------------------OLD IP CONFIG MAP--------------------------+"
            cat /data/redis/cluster-old.ip
            echo_info "+-------------------------NEW IP CONFIG MAP--------------------------+"
            cat /data/redis/cluster-new.ip
            echo_info "+-------------------------OLD CLUSTER NODE---------------------------+"
            cat /data/redis/nodes.conf
            
            index=0
            cat /data/redis/cluster-old.ip | while read oldip 
            do
                # newip=$(sed -n "$index"p /data/redis/cluster-new.ip)
                sed -i "s/${oldip}/pod${index}/g" /data/redis/nodes.conf
                let index++
            done

            index=0
            cat /data/redis/cluster-new.ip | while read newip 
            do
                # newip=$(sed -n "$index"p /data/redis/cluster-new.ip)
                sed -i "s/pod${index}/${newip}/g" /data/redis/nodes.conf
                let index++
            done
            
            
            echo_info "+-------------------------NEW CLUSTER NODE---------------------------+"
            cat /data/redis/nodes.conf
        else
            log_error "[ERROR] something wrong with presistent"
        fi
    fi
    # use k8s environment
    log_info "Starting cluster ..."

    if test -f "/config/redis/cluster.conf" ; then
        cp /config/redis/cluster.conf /data/redis/cluster.conf
    else
        log_error "Sorry , I cant find file -> /config/redis/cluster.conf"
    fi

    echo "port ${REDIS_PORT}" >> /data/redis/cluster.conf
    echo "bind ${MY_POD_IP} 127.0.0.1 " >> /data/redis/cluster.conf
    echo "daemonize yes" >> /data/redis/cluster.conf

    echo "slave-announce-ip ${MY_POD_IP}" >> /data/redis/cluster.conf
    echo "slave-announce-port ${REDIS_PORT}" >> /data/redis/cluster.conf

    echo "cluster-announce-ip ${MY_POD_IP}" >> /data/redis/cluster.conf
    echo "cluster-announce-port ${REDIS_PORT}" >> /data/redis/cluster.conf

    echo "logfile /data/redis/redis.log" >> /data/redis/cluster.conf

    redis-server /data/redis/cluster.conf --protected-mode no

    while true ; do 
        CLUSTER_CHECK_RESULT=$(/code/redis/redis-trib.rb check --health ${MY_POD_IP}:$REDIS_PORT | jq ".code")
        RESULT_LENGTH=$(echo $CLUSTER_CHECK_RESULT | wc -L)
        if test $RESULT_LENGTH != "1" ; then
            sleep 10
            continue
        fi

        log_info ">>> Health Result: ${CLUSTER_CHECK_RESULT}"
        if test $CLUSTER_CHECK_RESULT == "0" ; then 
            log_info ">>> Back up nodes.conf"
            save_relation "old"
        fi
        sleep 10
    done
}

# 集群模式 集群配置节点启动流程代码
function cluster_ctrl_launcher(){

    echo_info "+--------------------------------------------------------------------+"
    echo_info "|                                                                    |"
    echo_info "|\t\t\tCLUSTER_SVC  : $CLUSTER_SVC     "
    echo_info "|\t\t\tAPI_SERVER_ADDR   : $API_SERVER_ADDR   "
    echo_info "|\t\t\tREDIS_CLUSTER_SLAVE_QUANTUM  : $REDIS_CLUSTER_SLAVE_QUANTUM    "
    echo_info "|                                                                    |"
    echo_info "+--------------------------------------------------------------------+"

    while true ; do
        Listener=$(curl -s ${API_SERVER_ADDR}/apis/apps/v1/namespaces/default/statefulsets/sts-redis-cluster | jq ".code")
        if [[ $Listener == "404" ]] ; then
            echo_info ">>> Api server address: ${API_SERVER_ADDR}"
            echo_info ">>> Waiting Until the StatefulSet -> sts-redis-cluster is Created... "
            sleep 20
            continue
        else
            break
        fi
    done

    while true; do
        
        log_info ">>> Performing Cluster Config Check"
        REPLICAS=$(curl -s ${API_SERVER_ADDR}/apis/apps/v1/namespaces/default/statefulsets/sts-redis-cluster | jq ".spec.replicas")
        NODES=$(curl -s ${API_SERVER_ADDR}/api/v1/nodes | jq ".items | length")
        HOST_NETWORK=$(curl -s ${API_SERVER_ADDR}/apis/apps/v1/namespaces/default/statefulsets/sts-redis-cluster | jq ".spec.template.spec.hostNetwork" )

        echo_info "+--------------------------------------------------------------------+"
        echo_info "|                                                                    |"
        echo_info "|\t\t\tREPLICAS: $REPLICAS"
        echo_info "|\t\t\tNODES: $NODES"
        echo_info "|\t\t\tHOST_NETWORK: $HOST_NETWORK"
        echo_info "|                                                                    |"
        echo_info "+--------------------------------------------------------------------+"

        let CLUSER_POD_QUANTUM=REDIS_CLUSTER_SLAVE_QUANTUM*3+3
        if test $REPLICAS -lt $CLUSER_POD_QUANTUM ; then
        #  这个情况下是因为组成不了集群,所以直接报错退出
            log_error " We Need More Pods, please reset the \"replicas\" in  sts-redis-cluster.yaml and recreate the StatefulSet"
            log_error "[IMPORTANT]   =>   pod_replicas >= (slave_replicas + 1) * 3"
            exit 1
        elif [[ $REPLICAS -gt $NODES ]] && [[ $HOST_NETWORK == "true"  ]]; then
            log_error "We Need More Nodes,please reset the \"replicas\" in  sts-redis-cluster.yaml and recreate the StatefulSet or addd nodes "
            exit 1
        else
            log_info "[OK] Cluster Config OK..."
        fi

        log_info ">>> Performing Redis Cluster Pod Check..."

        IP_ARRAY=$(nslookup $CLUSTER_SVC | grep 'Address' |awk '{print $3}')
        # log_info "Ready Pod IP : $IP_ARRAY"
        CLUSTER_CONFIG=""
        index=0
        for ip in $IP_ARRAY ;
        do
            redis-cli -h ${ip} -p ${REDIS_PORT} INFO > tempinfo.log
            if test "$?" != "0" ; then
                log_error " Connected to $ip failed ,execute break"
                break
            fi
            CLUSTER_CONFIG=${ip}":${REDIS_PORT} "${CLUSTER_CONFIG}
            # log_info "Cluster config : $CLUSTER_CONFIG"
            CLUSTER_NODE=${ip}
            let index++
        done

        log_info "index : $index "
        if test $index -eq $REPLICAS ; then
            log_info ">>> Performing Check Recovery..."
            RECOVERD=$(/code/redis/redis-trib.rb check --health sts-redis-cluster-0.svc-redis-cluster:$REDIS_PORT | jq ".code")
            RESULT_LENGTH=$(echo $RECOVERD | wc -L)
            if test $RESULT_LENGTH != "1" ; then
                continue
            else
                if test $RECOVERD == "0" ; then 
                    log_info ">>> Recover from the destruction"
                    break 
                fi
            fi

            log_info ">>> Performing Build Redis Cluster..."
            if test $REDIS_CLUSTER_SLAVE_QUANTUM -eq 0 ;then
                yes yes | head -1 | /code/redis/redis-trib.rb create  $CLUSTER_CONFIG
            else
                yes yes | head -1 | /code/redis/redis-trib.rb create --replicas $REDIS_CLUSTER_SLAVE_QUANTUM $CLUSTER_CONFIG
            fi
            log_info "[OK] Congratulations,Redis Cluster Completed!"
            break
        else
            log_info "Waiting for all pod to be ready! Sleep 5 secs..."
            sleep 10
            continue
        fi
    done

    while true ; do
        log_info ">>> Performing Check Redis Cluster Pod Replicas"
        NEW_REPLICAS=$(curl -s ${API_SERVER_ADDR}/apis/apps/v1/namespaces/default/statefulsets/sts-redis-cluster | jq ".spec.replicas")
        NODES=$(curl -s ${API_SERVER_ADDR}/api/v1/nodes | jq ".items | length")
        HOST_NETWORK=$(curl -s ${API_SERVER_ADDR}/apis/apps/v1/namespaces/default/statefulsets/sts-redis-cluster | jq ".spec.template.spec.hostNetwork" )
        log_info "Current Pod Replicas : $NEW_REPLICAS"
        log_info "Current Nodes Quantum : $NODES"

        #  这里还要判断 NEW_REPLICAS NODES 和 REPLICAS 的关系
        #  如果采用了hostnetwork 的话,pod的数量不能大于 nodes的数量,所以 NEW_REPLICAS > NODES => NEW_REPLICAS=NODES

        if test $NEW_REPLICAS -gt $NODES ; then
            if test $HOST_NETWORK == "true" ; then
                log_warn " When you use host network,make sure that the number of pod is less than node"
                NEW_REPLICAS=$NODES
            fi
        fi

        if test $NEW_REPLICAS -ge $REPLICAS ;then
            if test $NEW_REPLICAS -eq $REPLICAS ;then
                log_info ">>> Performing Check Redis Cluster..."
                /code/redis/redis-trib.rb check $CLUSTER_NODE:$REDIS_PORT
                sleep 180
            else
                log_info ">>> Performing Add Node To The Redis Cluster"
                while true ; do
                    NEW_IP_ARRAY=$(nslookup $CLUSTER_SVC | grep 'Address' |awk '{print $3}')
                    log_info "Ready Pod IP : $NEW_IP_ARRAY"
                    new_index=0
                    for ip in $NEW_IP_ARRAY ;
                    do
                        redis-cli -h ${ip} -p ${REDIS_PORT} INFO > tempinfo.log
                        if test "$?" != "0" ; then
                            log_error " Connected to $ip failed ,execute break"
                            break
                        fi
                        # CLUSTER_NODE=${ip}
                        let new_index++
                    done

                    log_info "index : $new_index "

                    if test $new_index -ge $NEW_REPLICAS ; then
                        log_info ">>> Performing Add New Node To The Existed Redis Cluster..."

                        for ip_a in $NEW_IP_ARRAY ; do
                            EXISTS=0
                            for ip_b in $IP_ARRAY ; do 
                                if test $ip_a == $ip_b ; then
                                    EXISTS=1
                                    break
                                fi
                            done
                            
                            if  test $EXISTS -eq 0 ; then 
                                # 这里的auto就是之前改的redis-trib.rb,新增进去的子命令,用于自动迁移slot
                                # /code/redis/redis-trib.rb add-node --auto $ip_a:$REDIS_PORT  $CLUSTER_NODE:$REDIS_PORT
                                # 集群扩容暂时有问题,先默认添加的节点为slave
                                /code/redis/redis-trib.rb add-node --slave $ip_a:$REDIS_PORT  $CLUSTER_NODE:$REDIS_PORT
                            fi
                        done

                        REPLICAS=$NEW_REPLICAS

                        log_info "[OK] Congratulations,Redis Cluster Completed!"
                        break
                    else
                        log_info "Waiting for all pod to be ready! sleep 5 secs..."
                        sleep 5
                        continue
                    fi
                done
            fi
        else
            log_error "Sorry,We do not support the delete node operation"
        fi
    done
}


if test $# -ne 0 ; then
    case $1 in
        "health")
            # --health 命令不是原生的,对 redis-trib.rb 做过修改
            /code/redis/redis-trib.rb check --health sts-redis-cluster-0.svc-redis-cluster:$REDIS_PORT
            ;;
        *)
            log_error "wrong arguments!"
        ;;
    esac
    exit 0
fi

time=$(date "+%Y-%m-%d")

echo_info "+--------------------------------------------------------------------+"
echo_info "|                                                                    |"
echo_info "|\t\t\t Redis-in-Kubernetes"
echo_info "|\t\t\t Author: caiqyxyx"
echo_info "|\t\t\t Github: https://github.com/marscqy/redis-in-k8s"
echo_info "|\t\t\t Start Date: $time"
echo_info "|                                                                    |"
echo_info "+--------------------------------------------------------------------+"

# 安装 redis-trib.rb 的依赖
# gem install --local /rdoc-600.gem
# gem install --local /redis-401.gem

if [[ $MASTER == "true" ]] ; then
    master_launcher
    exit 0
fi

if [[ $SLAVE == "true" ]] ; then
    slave_launcher
    exit 0
fi

if [[ $SENTINEL == "true" ]] ; then
    sentinel_launcher
    exit 0
fi

if [[ $CLUSTER == "true" ]] ; then
    cluster_launcher
    exit 0
fi

if [[ $CLUSTER_CTRL == "true" ]] ; then
    cluster_ctrl_launcher
    exit 0
fi