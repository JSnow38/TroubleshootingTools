#!/bin/bash

if [ "$#" -eq 0 ];
then
  echo "CoreDNS CheckUp"
  echo "Usage: "
  echo "kubednscheck "
  IPS=$(kubectl get pod --namespace=kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}')
  echo "Deploy nginx test Pod"
  kubectl run nginx --image=nginx
  sleep 8
  kubectl exec -it nginx -- apt update
  kubectl exec -it nginx -- apt install netcat -y
  kubectl exec -it nginx -- apt install dnsutils -y
  for instance in $IPS;
    do
      for i in {1..20}; do kubectl exec -it nginx --  nc -zv $instance 53; done;
  done
elif [[ "$1" == "query" ]];
then
  IPS=$(kubectl get pod --namespace=kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}')
  for instance in $IPS;
    do
      for i in {1..20}; do kubectl exec -it nginx --  nslookup microsoft.com $instance; done;
  done
elif [[ "$1" == "reload" ]];
then
  POD=$(kubectl get pod --namespace=kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].metadata.name}')
  for podName in $POD;
     do
       kubectl delete pod -n kube-system $podName;
     done
elif [[ "$1" == "logging" ]];
then
cat << EOF > ./coredns-logging.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  log.override: | # you may select any name here, but it must end with the .override file extension
        log
EOF
kubectl apply -f ./coredns-logging.yaml
fi