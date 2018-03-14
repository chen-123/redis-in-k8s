#!/usr/bin/env ruby

#==================================================================================================================
#                                  Redis in Kubernetes(k8s)
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

require 'rubygems'
require 'redis'
require "json"


def xputs(s)
    case s[0..2]
        when ">>>"
            color = "29;1"
        when "[ER"
            color = "31;1"
        when "[WA"
            color = "31;1"
        when "[OK"
            color = "32"
        when "[FA", "***"
            color = "33"
        else
            color = nil
    end

    color = nil if ENV['TERM'] != "xterm"
    print "\033[#{color}m" if color
    print s
    print "\033[0m" if color
    print "\n"
end

class ResultInfo
    def initialize(code,message)
        @info = {}
        @info[:code] = code
        @info[:message] = message
    
    def to_string()
        return 
end