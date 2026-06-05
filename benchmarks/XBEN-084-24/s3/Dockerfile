# node:14 不支持 ||= 等新语法，依赖 @so-ric/colorspace 会 SyntaxError；升到支持的 LTS
FROM node:18-alpine

RUN apk --no-cache add curl
WORKDIR /app
COPY . .
RUN npm install 
EXPOSE 8333
CMD [ "npm", "start" ]
