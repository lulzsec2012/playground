#!/bin/bash

OLLAMA_URL="http://10.10.18.210:10434"

echo "=== Ollama 服务测试 ==="

# 1. 基础连通性
echo -e "\n1. 基础连通性测试:"
curl -s $OLLAMA_URL && echo ""

# 2. 列出模型
echo -e "\n2. 已安装模型列表:"
curl -s $OLLAMA_URL/api/tags | jq -r '.models[] | "  - \(.name) (\(.parameter_size))"'

# 3. 查看 qwen3-coder-next 模型详情
echo -e "\n3. qwen3-coder-next 模型详情:"
curl -s -X POST $OLLAMA_URL/api/show \
  -H "Content-Type: application/json" \
  -d '{"name": "qwen3-coder-next:latest"}' \
  | jq '{model: .model, parameter_size: .details.parameter_size, quantization: .details.quantization_level}'

# 4. 简单测试生成（非流式）
echo -e "\n4. 测试模型生成:"
curl -s -X POST $OLLAMA_URL/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-coder-next:latest",
    "prompt": "Say OK in one word",
    "stream": false,
    "options": {"num_predict": 10}
  }' \
  | jq -r '.response'

echo -e "\n=== 测试完成 ==="