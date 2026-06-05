FROM nginx:alpine

# 复制 nginx 配置
COPY nginx.conf /etc/nginx/nginx.conf

# 编号->端口映射表（由 start-gateway.sh 自动生成）
COPY ports.map /etc/nginx/ports.map

# 复制 HTML 文件
COPY index.html /usr/share/nginx/html/index.html

# 暴露端口
EXPOSE 80

# 健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
