# Gateway 目录

Validation Benchmarks 的统一访问网关。

## 目录内容

- **index.html**: 导航主页，提供所有 benchmark 的可视化列表和搜索功能
- **nginx.conf**: Nginx 反向代理配置，将不同路径映射到对应的 benchmark 容器
- **Dockerfile**: Nginx 容器构建文件

## 使用方式

不要直接在此目录操作，请返回项目根目录使用 `start-gateway.sh` 脚本。

```bash
cd ..
./start-gateway.sh full
```

详细文档请查看根目录的 `GATEWAY-README.md`。
