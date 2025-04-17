# Remove Helm Chart Default Values

## Usage

```
# Example: Using a pre-added repository alias 'prometheus-community'
# (Ensure 'helm repo add prometheus-community https://...' was run before)
./helm_diff_values.py \
  --repo prometheus-community \
  --chart kube-prometheus-stack \
  --version 58.1.0 \
  my-local-kube-prometheus-values.yaml

# Example: Adding the repo on the fly and updating repos first
./helm_diff_values.py \
  --repo prom-comm=https://prometheus-community.github.io/helm-charts \
  --chart kube-prometheus-stack \
  --version 58.1.0 \
  --add-repo \
  --update-repo \
  my-local-kube-prometheus-values.yaml \
  -o minimal-values.yaml
```
