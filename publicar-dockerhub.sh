#!/usr/bin/env bash
set -euo pipefail

dockerhub_user="${1:-}"
image_tag="${2:-v1.0.0}"

if [[ ! "$dockerhub_user" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  printf 'Uso: bash publicar-dockerhub.sh guilhermebarros297 [TAG]\n' >&2
  exit 1
fi
if [[ ! "$image_tag" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
  printf 'Tag de imagem invalida.\n' >&2
  exit 1
fi

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$project_root"

docker info > /dev/null
docker login --username "$dockerhub_user"

docker build -f BackEnd_Grupo7/Docker/Dockerfile -t "$dockerhub_user/codetracker-backend:$image_tag" BackEnd_Grupo7
docker build -t "$dockerhub_user/codetracker-etiquetas:$image_tag" Etiquetas_Grupo7
docker build -t "$dockerhub_user/codetracker-frontend:$image_tag" FrontEnd_Grupo7/codetracker

for service in backend etiquetas frontend; do
  image="$dockerhub_user/codetracker-$service:$image_tag"
  docker push "$image"
  printf 'Imagem publicada: %s\n' "$image"
done