FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --production

COPY . .

# Create data directory
RUN mkdir -p data uploads

EXPOSE 3001

CMD ["npm", "start"]
