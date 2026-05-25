# Setup Kubernetes
## Semua Node (k8s-main, k8s-worker-1)
### Konfigurasi OS & Jaringan

**Matikan Swap:** Kubernetes (Kubelet) menuntut swap dimatikan agar alokasi memori (RAM) ke Pod bisa diukur secara presisi.

**Modul Kernel & Sysctl:** Mengaktifkan _IP forwarding_ dan memastikan _bridge network_ (lalu lintas antar container) terbaca oleh iptables untuk kebutuhan keamanan dan routing.

```bash
sudo swapoff -a
```

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
```

```bash
sudo modprobe overlay
```

```bash
sudo modprobe br_netfilter
```

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
```

```bash
sudo sysctl --system
```

### Install Container Runtime

**Install Container Runtime (Containerd):** Mesin yang menjalankan container Anda. Kita mengaktifkan `SystemdCgroup = true` agar manajemen resource selaras antara containerd dan systemd bawaan OS.

```bash
sudo apt-get update
```

```bash
sudo apt-get install -y containerd
```

```bash
sudo mkdir -p /etc/containerd
```

```bash
containerd config default | sudo tee /etc/containerd/config.toml
```

```bash
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
```

```bash
sudo systemctl restart containerd
```

```bash
sudo systemctl enable containerd
```

### Install Kubeadm, Kubelet, dan Kubectl

```bash
sudo apt-get update
```

```bash
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
```

```bash
sudo mkdir -p -m 755 /etc/apt/keyrings
```

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

```bash
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
```

```bash
sudo apt-get update
```

```bash
sudo apt-get install -y kubelet kubeadm kubectl
```

```bash
sudo apt-mark hold kubelet kubeadm kubectl
```

## Master Node (k8s-main)
### Inisialisasi Control Plane

```bash
sudo kubeadm init --apiserver-advertise-address=192.168.4.5 --pod-network-cidr=10.244.0.0/16
```
**Catatan:** Nilai `--pod-network-cidr=10.244.0.0/16` biasa digunakan oleh CNI Flannel. Jika Anda berencana menggunakan Calico, gunakan `192.168.0.0/16`.

Agar bisa menggunakan perintah `kubectl` tanpa `sudo`, jalankan ini di Master Node:
```bash
mkdir -p $HOME/.kube
```

```bash
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
```

```bash
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Install Pod Network Add-on/CNI

**Install CNI (Flannel):** Memberikan alamat IP ke setiap Pod dan membangun jaringan virtual agar Pod di Node A bisa ping Pod di Node B.
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

cek status Node:
```bash
kubectl get nodes
```

## Worker Node (k8s-worker-1)
### Gabungkan Worker Node

**Join Worker:** Menggabungkan Node ke cluster. Dijalankan **di Master** untuk mendapat token, lalu ditempel **di Worker**.
```bash
kubeadm token create --print-join-command
```
Jalankan perintah `kubeadm join` yang tadi muncul di akhir output.

```bash
sudo kubeadm join 192.168.4.5:6443 --token <token-anda> --discovery-token-ca-cert-hash sha256:<hash-anda>
```

## Master Node (k8s-main)
### Cek Status Node

```bash
kubectl get nodes
```
**Labeling Node:** (Opsional) Memberi stempel "worker" pada node agar mudah diidentifikasi.
```bash
kubectl label node k8s-worker-1 node-role.kubernetes.io/worker=worker
```

### Install Tools Esensial
#### Install Helm

**Helm:** _Package manager_ (seperti `apt` tapi untuk Kubernetes).
```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
```

```bash
chmod 700 get_helm.sh
```

```bash
./get_helm.sh
```

#### Install Sealed Secrets Controller

**Sealed Secrets:** Agar password/secret aman disimpan di Git (dienkripsi).
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
```

```bash
helm repo update
```

```bash
helm install sealed-secrets-controller sealed-secrets/sealed-secrets -n kube-system
```

##### Restore Private Key Lama (Jika Migrasi)

```bash
kubectl apply -f main-sealed-secret-key.yaml -n kube-system
```

```bash
kubectl rollout restart deployment sealed-secrets-controller -n kube-system
```

Verfikasi:
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets
```

##### Apply File Sealed Secret

```bash
kubectl apply -f secret.yaml
```

##### Verifikasi Hasil Dekripsi

```bash
kubectl get secret
```

```bash
kubectl get secret <nama-secret> -o jsonpath="{.data}"
```

#### Membuat Namespace

```bash
kubectl create namespace <nama-namespace>
```

Verfikasi
```bash
kubectl get namespaces
```

#### Install Rancher Local Path Provisioner

**Local Path Provisioner:** Menyediakan _Persistent Volume_ (storage otomatis) menggunakan disk lokal pada Node.
```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
```

```bash
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Verifikasi:
```bash
kubectl get sc
```

#### Install Cert-Manager

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
```

```bash
helm install cert-manager jetstack/cert-manager \
	--namespace cert-manager \
	--create-namespace \
	--set crds.enabled=true
```

#### Install NGINX Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
```

```bash
helm repo update
```

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
	--namespace ingress-nginx \
	--create-namespace \
	--set controller.hostNetwork=true \
	--set controller.service.type=ClusterIP \
	--set controller.kind=DaemonSet
```

#### Debugging Kubernetes
##### Cek Status Pod

Melihat semua Pod di semua namespace.
```bash
kubectl get pods -A
```

##### Deskripsi Pod

```bash
kubectl describe pod <nama-pod> -n <namespace>
```

##### Cek Log Pod

```bash
kubectl logs <nama-pod> -n <namespace>
```
Jika Pod punya log sebelumnya yang crash:
```bash
kubectl logs <nama-pod> --previous -n <namespace>
```

##### Masuk ke dalam Container Pod

```bash
kubectl exec -it <nama-pod> -n <namespace> -- sh
```

##### Cek Status Node

Melihat daftar mesin (Master/Worker) beserta statusnya.
```bash
kubectl get nodes
```

##### Deskripsi Node

```bash
kubectl describe node <nama-node>
```

##### Cek Status Service

Melihat service (IP/Port yang terekspos) di namespace tertentu.
```bash
kubectl get svc -n <ns>
```

##### Cek Status Ingress

Melihat daftar routing URL/Domain web.
```bash
kubectl get ingress
```

##### Cek Status Persistent Volume Claim

Melihat status volume storage (disk).
```bash
kubectl get pvc,pv
```

---

## Eksekusi Manifest (Deploy)

Manifest di folder ini di-organize per concern (`data/`, `app/`, `proxy/`) dan di-manage pakai [Kustomize](https://kustomize.io/) (built-in di `kubectl` sejak v1.14). Tiap folder punya `kustomization.yaml` yang mendefinisikan urutan resource yang di-apply.

### Prasyarat

1. **Namespace** sudah dibuat:
   ```bash
   kubectl create namespace laravel
   ```
2. **cert-manager** ter-install (untuk `ClusterIssuer` di `proxy/`):
   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
   ```
3. **sealed-secrets controller** ter-install (untuk `SealedSecret`):
   ```bash
   kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
   ```
4. **Ingress controller** sudah aktif (NGINX Ingress, atau `microk8s enable ingress` untuk microk8s).

### Urutan Apply

Urutan penting karena ada dependency: data (DB/cache) → app (yang butuh DB) → proxy (yang expose app).

```bash
# 1. Data layer (postgres + redis + secret DB)
kubectl apply -k .k8s/data

# 2. Application layer (deployment + configmap + migration job + secret app)
kubectl apply -k .k8s/app

# 3. Proxy layer (cluster-issuer + ingress)
kubectl apply -k .k8s/proxy
```

### Preview Sebelum Apply (Dry-run)

Lihat hasil rendering manifest tanpa apply ke cluster:

```bash
kubectl kustomize .k8s/app          # render ke stdout
kubectl apply -k .k8s/app --dry-run=client -o yaml
```

### Verifikasi Deployment

```bash
kubectl -n laravel get all
kubectl -n laravel get pvc,ingress,sealedsecret
kubectl -n laravel rollout status deployment/app
kubectl -n laravel logs -l app.kubernetes.io/part-of=laravel --tail=50
```

### Update Manifest

Edit file YAML, lalu re-apply dengan command yang sama (`kubectl apply -k ...`). Kustomize akan menghitung diff dan hanya update resource yang berubah.

### Teardown

```bash
kubectl delete -k .k8s/proxy
kubectl delete -k .k8s/app
kubectl delete -k .k8s/data
# Hapus namespace (akan menghapus semua resource namespaced sekaligus)
kubectl delete namespace laravel
```

> **Catatan untuk MicroK8s**: gunakan folder `.microk8s/` (struktur identik, beberapa nilai disesuaikan untuk single-node microk8s). Ganti `.k8s/` dengan `.microk8s/` di semua command di atas. Pastikan addon yang dibutuhkan aktif: `microk8s enable dns ingress hostpath-storage cert-manager`.
