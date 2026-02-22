#!/bin/bash

PROJECT_NAME="sre-practice"
mkdir -p $PROJECT_NAME && cd $PROJECT_NAME

# Структура директорий
mkdir -p services/{api-gateway,order-service,payment-service,chaos-engine}
mkdir -p monitoring deploy

# === API GATEWAY ===
cat > services/api-gateway/main.go << 'EOF'
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	requestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "endpoint", "status"},
	)
	requestTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests",
		},
		[]string{"method", "endpoint", "status"},
	)
)

func init() {
	prometheus.MustRegister(requestDuration, requestTotal)
}

type OrderRequest struct {
	UserID  string  `json:"user_id"`
	Amount  float64 `json:"amount"`
	Product string  `json:"product"`
}

func main() {
	orderServiceURL := getEnv("ORDER_SERVICE_URL", "http://order-service:8081")
	paymentServiceURL := getEnv("PAYMENT_SERVICE_URL", "http://payment-service:8082")

	mux := http.NewServeMux()
	
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"status": "healthy", "service": "api-gateway"})
	})

	mux.Handle("/metrics", promhttp.Handler())

	mux.HandleFunc("/api/order", instrumentHandler("create_order", handleCreateOrder(orderServiceURL)))
	mux.HandleFunc("/api/pay", instrumentHandler("process_payment", handleProcessPayment(paymentServiceURL)))
	mux.HandleFunc("/api/status/", instrumentHandler("get_status", handleGetStatus(orderServiceURL)))

	port := getEnv("PORT", "8080")
	host := getEnv("HOST", "0.0.0.0")
	log.Printf("API Gateway starting on %s:%s", host, port)
	log.Fatal(http.ListenAndServe(host+":"+port, mux))
}

func instrumentHandler(name string, handler http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{w, http.StatusOK}
		
		handler(rw, r)
		
		duration := time.Since(start).Seconds()
		status := fmt.Sprintf("%d", rw.statusCode)
		
		requestDuration.WithLabelValues(r.Method, name, status).Observe(duration)
		requestTotal.WithLabelValues(r.Method, name, status).Inc()
	}
}

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

func handleCreateOrder(orderServiceURL string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req OrderRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		resp, err := http.Post(
			orderServiceURL+"/orders",
			"application/json",
			r.Body,
		)
		if err != nil {
			log.Printf("Error forwarding to order service: %v", err)
			http.Error(w, "Service unavailable", http.StatusServiceUnavailable)
			return
		}
		defer resp.Body.Close()

		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}
}

func handleProcessPayment(paymentServiceURL string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		resp, err := http.Post(
			paymentServiceURL+"/payments",
			"application/json",
			r.Body,
		)
		if err != nil {
			log.Printf("Error forwarding to payment service: %v", err)
			http.Error(w, "Service unavailable", http.StatusServiceUnavailable)
			return
		}
		defer resp.Body.Close()

		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}
}

func handleGetStatus(orderServiceURL string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		orderID := r.URL.Path[len("/api/status/"):]
		resp, err := http.Get(orderServiceURL + "/orders/" + orderID + "/status")
		if err != nil {
			log.Printf("Error getting status: %v", err)
			http.Error(w, "Service unavailable", http.StatusServiceUnavailable)
			return
		}
		defer resp.Body.Close()

		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
EOF

cat > services/api-gateway/go.mod << 'EOF'
module api-gateway
go 1.21
require github.com/prometheus/client_golang v1.17.0
EOF

cat > services/api-gateway/Dockerfile << 'EOF'
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod tidy && go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .
FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/main .
EXPOSE 8080
CMD ["./main"]
EOF

# === ORDER SERVICE ===
cat > services/order-service/main.go << 'EOF'
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	db             *sql.DB
	serviceLatency = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "order_service_latency_seconds",
			Help:    "Order processing latency",
			Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10},
		},
	)
	activeOrders = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "active_orders_total",
			Help: "Current active orders",
		},
	)
)

func init() {
	prometheus.MustRegister(serviceLatency, activeOrders)
}

type Order struct {
	ID        string    `json:"id"`
	UserID    string    `json:"user_id"`
	Amount    float64   `json:"amount"`
	Product   string    `json:"product"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

func main() {
	var err error
	
	dbHost := getEnv("DB_HOST", "postgres")
	dbPort := getEnv("DB_PORT", "5432")
	dbUser := getEnv("DB_USER", "postgres")
	dbPass := getEnv("DB_PASSWORD", "postgres")
	dbName := getEnv("DB_NAME", "orders")

	connStr := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		dbHost, dbPort, dbUser, dbPass, dbName)

	db, err = sql.Open("postgres", connStr)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	initDB()

	mux := http.NewServeMux()
	
	mux.HandleFunc("/health", healthHandler)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/orders", ordersHandler)
	mux.HandleFunc("/orders/", orderStatusHandler)

	port := getEnv("PORT", "8081")
	host := getEnv("HOST", "0.0.0.0")
	log.Printf("Order Service starting on %s:%s", host, port)
	log.Fatal(http.ListenAndServe(host+":"+port, mux))
}

func initDB() {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS orders (
			id UUID PRIMARY KEY,
			user_id VARCHAR(255) NOT NULL,
			amount DECIMAL(10,2) NOT NULL,
			product VARCHAR(255) NOT NULL,
			status VARCHAR(50) DEFAULT 'pending',
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		)
	`)
	if err != nil {
		log.Fatal("Failed to create table:", err)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if err := db.Ping(); err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{
			"status": "unhealthy",
			"error":  "database unavailable",
		})
		return
	}
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "healthy",
		"service": "order-service",
	})
}

func ordersHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	defer func() {
		serviceLatency.Observe(time.Since(start).Seconds())
	}()

	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var order Order
	if err := json.NewDecoder(r.Body).Decode(&order); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Хаос: случайная задержка
	delay := time.Duration(rand.Intn(100)) * time.Millisecond
	if rand.Float32() < 0.1 {
		delay = time.Duration(rand.Intn(2000)+1000) * time.Millisecond
	}
	time.Sleep(delay)

	order.ID = uuid.New().String()
	order.Status = "pending"
	order.CreatedAt = time.Now()

	_, err := db.Exec(
		"INSERT INTO orders (id, user_id, amount, product, status, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
		order.ID, order.UserID, order.Amount, order.Product, order.Status, order.CreatedAt,
	)
	if err != nil {
		log.Printf("Database error: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	activeOrders.Inc()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(order)
}

func orderStatusHandler(w http.ResponseWriter, r *http.Request) {
	orderID := r.URL.Path[len("/orders/"):len(r.URL.Path)-len("/status")]
	
	var status string
	err := db.QueryRow("SELECT status FROM orders WHERE id = $1", orderID).Scan(&status)
	if err == sql.ErrNoRows {
		http.Error(w, "Order not found", http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("Database error: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]string{
		"order_id": orderID,
		"status":   status,
	})
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
EOF

cat > services/order-service/go.mod << 'EOF'
module order-service
go 1.21
require (
	github.com/google/uuid v1.3.1
	github.com/lib/pq v1.10.9
	github.com/prometheus/client_golang v1.17.0
)
EOF

cat > services/order-service/Dockerfile << 'EOF'
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod tidy && go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .
FROM alpine:latest
RUN apk --no-cache add ca-certificates wget
WORKDIR /root/
COPY --from=builder /app/main .
EXPOSE 8081
CMD ["./main"]
EOF

# === PAYMENT SERVICE ===
cat > services/payment-service/main.go << 'EOF'
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	paymentAttempts = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "payment_attempts_total",
			Help: "Total payment attempts",
		},
		[]string{"status"},
	)
	paymentAmount = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "payment_amount_usd",
			Help:    "Payment amounts",
			Buckets: []float64{10, 50, 100, 500, 1000, 5000},
		},
	)
)

func init() {
	prometheus.MustRegister(paymentAttempts, paymentAmount)
}

type PaymentRequest struct {
	OrderID string  `json:"order_id"`
	Amount  float64 `json:"amount"`
	Method  string  `json:"method"`
}

type PaymentResponse struct {
	TransactionID string `json:"transaction_id"`
	Status        string `json:"status"`
	Message       string `json:"message"`
}

func main() {
	mux := http.NewServeMux()
	
	mux.HandleFunc("/health", healthHandler)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/payments", paymentHandler)

	port := getEnv("PORT", "8082")
	host := getEnv("HOST", "0.0.0.0")
	log.Printf("Payment Service starting on %s:%s", host, port)
	log.Fatal(http.ListenAndServe(host+":"+port, mux))
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if rand.Float32() < 0.05 {
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{"status": "degraded"})
		return
	}
	json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
}

func paymentHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req PaymentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	paymentAmount.Observe(req.Amount)

	// Симуляция обработки
	time.Sleep(time.Duration(rand.Intn(500)) * time.Millisecond)

	response := PaymentResponse{
		TransactionID: fmt.Sprintf("txn_%d", rand.Int63()),
	}

	// Хаос: 15% ошибок, 5% таймаутов
	randVal := rand.Float32()
	switch {
	case randVal < 0.05:
		time.Sleep(10 * time.Second)
		response.Status = "timeout"
		response.Message = "Payment gateway timeout"
		paymentAttempts.WithLabelValues("timeout").Inc()
		w.WriteHeader(http.StatusGatewayTimeout)
	case randVal < 0.20:
		response.Status = "failed"
		response.Message = "Insufficient funds"
		paymentAttempts.WithLabelValues("failed").Inc()
		w.WriteHeader(http.StatusPaymentRequired)
	default:
		response.Status = "success"
		response.Message = "Payment processed"
		paymentAttempts.WithLabelValues("success").Inc()
		w.WriteHeader(http.StatusOK)
	}

	json.NewEncoder(w).Encode(response)
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
EOF

cat > services/payment-service/go.mod << 'EOF'
module payment-service
go 1.21
require github.com/prometheus/client_golang v1.17.0
EOF

cat > services/payment-service/Dockerfile << 'EOF'
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod tidy && go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .
FROM alpine:latest
RUN apk --no-cache add ca-certificates wget
WORKDIR /root/
COPY --from=builder /app/main .
EXPOSE 8082
CMD ["./main"]
EOF

# === CHAOS ENGINE ===
cat > services/chaos-engine/main.go << 'EOF'
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type ChaosConfig struct {
	APIEndpoint      string
	MinInterval      time.Duration
	MaxInterval      time.Duration
	BurstProbability float64
}

func main() {
	config := ChaosConfig{
		APIEndpoint:      getEnv("API_ENDPOINT", "http://api-gateway:8080"),
		MinInterval:      100 * time.Millisecond,
		MaxInterval:      2 * time.Second,
		BurstProbability: 0.3,
	}

	log.Println("Chaos Engine starting...")
	log.Printf("Target: %s", config.APIEndpoint)

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	ticker := time.NewTicker(config.MinInterval)
	defer ticker.Stop()

	burstChan := make(chan bool)
	go burstGenerator(burstChan, config)

	requestCount := 0
	startTime := time.Now()

	for {
		select {
		case <-sigChan:
			duration := time.Since(startTime)
			log.Printf("Shutdown. Total: %d requests in %v (%.2f req/sec)",
				requestCount, duration, float64(requestCount)/duration.Seconds())
			return
		case <-ticker.C:
			go generateLoad(config)
			requestCount++
		case isBurst := <-burstChan:
			if isBurst {
				burstSize := rand.Intn(40) + 10
				log.Printf("BURST: %d rapid requests", burstSize)
				for i := 0; i < burstSize; i++ {
					go generateLoad(config)
					requestCount++
					time.Sleep(time.Duration(rand.Intn(50)) * time.Millisecond)
				}
			}
		}

		newInterval := time.Duration(rand.Intn(int(config.MaxInterval-config.MinInterval))) + config.MinInterval
		ticker.Reset(newInterval)
	}
}

func burstGenerator(ch chan<- bool, config ChaosConfig) {
	for {
		time.Sleep(time.Duration(rand.Intn(30)+10) * time.Second)
		if rand.Float64() < config.BurstProbability {
			ch <- true
		}
	}
}

func generateLoad(config ChaosConfig) {
	operations := []func(string){
		createOrder,
		processPayment,
		checkStatus,
		sendInvalidRequest,
		sendMalformedJSON,
	}

	op := operations[rand.Intn(len(operations))]
	op(config.APIEndpoint)
}

func createOrder(baseURL string) {
	order := map[string]interface{}{
		"user_id": fmt.Sprintf("user_%d", rand.Intn(1000)),
		"amount":  rand.Float64() * 1000,
		"product": []string{"laptop", "phone", "tablet", "watch"}[rand.Intn(4)],
	}

	jsonData, _ := json.Marshal(order)
	resp, err := http.Post(baseURL+"/api/order", "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		log.Printf("Order error: %v", err)
		return
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body)
}

func processPayment(baseURL string) {
	payment := map[string]interface{}{
		"order_id": fmt.Sprintf("order_%d", rand.Intn(10000)),
		"amount":   rand.Float64() * 500,
		"method":   []string{"card", "paypal", "crypto"}[rand.Intn(3)],
	}

	jsonData, _ := json.Marshal(payment)
	resp, err := http.Post(baseURL+"/api/pay", "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		log.Printf("Payment error: %v", err)
		return
	}
	defer resp.Body.Close()
	if rand.Float32() > 0.1 {
		io.ReadAll(resp.Body)
	}
}

func checkStatus(baseURL string) {
	orderID := fmt.Sprintf("order_%d", rand.Intn(10000))
	resp, err := http.Get(baseURL + "/api/status/" + orderID)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body)
}

func sendInvalidRequest(baseURL string) {
	resp, err := http.Get(baseURL + "/api/nonexistent")
	if err != nil {
		return
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body)
}

func sendMalformedJSON(baseURL string) {
	malformed := `{"user_id": "test", "amount": }`
	resp, err := http.Post(baseURL+"/api/order", "application/json", bytes.NewBufferString(malformed))
	if err != nil {
		return
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body)
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
EOF

cat > services/chaos-engine/go.mod << 'EOF'
module chaos-engine
go 1.21
EOF

cat > services/chaos-engine/Dockerfile << 'EOF'
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod tidy && go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .
FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/main .
CMD ["./main"]
EOF

# === MONITORING CONFIGS ===
cat > monitoring/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'api-gateway'
    static_configs:
      - targets: ['api-gateway:8080']
    metrics_path: /metrics

  - job_name: 'order-service'
    static_configs:
      - targets: ['order-service:8081']
    metrics_path: /metrics

  - job_name: 'payment-service'
    static_configs:
      - targets: ['payment-service:8082']
    metrics_path: /metrics

  - job_name: 'postgres-exporter'
    static_configs:
      - targets: ['postgres-exporter:9187']

  - job_name: 'redis-exporter'
    static_configs:
      - targets: ['redis-exporter:9121']
EOF

cat > monitoring/loki-config.yml << 'EOF'
auth_enabled: false
server:
  http_listen_port: 3100
  grpc_listen_port: 9096
common:
  path_prefix: /tmp/loki
  storage:
    filesystem:
      chunks_directory: /tmp/loki/chunks
      rules_directory: /tmp/loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h
ruler:
  alertmanager_url: http://localhost:9093
limits_config:
  enforce_metric_name: false
  reject_old_samples: true
  reject_old_samples_max_age: 168h
EOF

cat > monitoring/datasource.yml << 'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
EOF

# === DOCKER COMPOSE ===
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: orders
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
    networks:
      - sre-network

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 256M
    networks:
      - sre-network

  api-gateway:
    build: ./services/api-gateway
    environment:
      - ORDER_SERVICE_URL=http://order-service:8081
      - PAYMENT_SERVICE_URL=http://payment-service:8082
      - PORT=8080
      - HOST=0.0.0.0
    ports:
      - "8080:8080"
    depends_on:
      - order-service
      - payment-service
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 3
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 128M
    networks:
      - sre-network

  order-service:
    build: ./services/order-service
    environment:
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_USER=postgres
      - DB_PASSWORD=postgres
      - DB_NAME=orders
      - REDIS_HOST=redis
      - PORT=8081
      - HOST=0.0.0.0
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8081/health"]
      interval: 10s
      timeout: 5s
      retries: 3
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 128M
    networks:
      - sre-network

  payment-service:
    build: ./services/payment-service
    environment:
      - PORT=8082
      - HOST=0.0.0.0
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8082/health"]
      interval: 10s
      timeout: 5s
      retries: 3
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 128M
    networks:
      - sre-network

  chaos-engine:
    build: ./services/chaos-engine
    environment:
      - API_ENDPOINT=http://api-gateway:8080
    depends_on:
      - api-gateway
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 64M
      restart_policy:
        condition: on-failure
    networks:
      - sre-network

  prometheus:
    image: prom/prometheus:v2.47.0
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=7d'
      - '--web.enable-lifecycle'
    ports:
      - "9090:9090"
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 512M
    networks:
      - sre-network

  loki:
    image: grafana/loki:2.9.0
    volumes:
      - ./monitoring/loki-config.yml:/etc/loki/local-config.yaml
    command: -config.file=/etc/loki/local-config.yaml
    ports:
      - "3100:3100"
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 256M
    networks:
      - sre-network

  grafana:
    image: grafana/grafana:10.1.0
    volumes:
      - ./monitoring/datasource.yml:/etc/grafana/provisioning/datasources/datasource.yml
      - grafana_data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    ports:
      - "3000:3000"
    depends_on:
      - prometheus
      - loki
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 256M
    networks:
      - sre-network

  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:v0.14.0
    environment:
      DATA_SOURCE_NAME: "postgresql://postgres:postgres@postgres:5432/orders?sslmode=disable"
    ports:
      - "9187:9187"
    depends_on:
      - postgres
    networks:
      - sre-network

  redis-exporter:
    image: oliver006/redis_exporter:latest
    environment:
      REDIS_ADDR: redis://redis:6379
    ports:
      - "9121:9121"
    depends_on:
      - redis
    networks:
      - sre-network

volumes:
  postgres_data:
  redis_data:
  prometheus_data:
  grafana_data:

networks:
  sre-network:
    driver: bridge
EOF

# === DEPLOY SCRIPT ===
cat > deploy.sh << 'EOF'
#!/bin/bash
set -e

echo "=== SRE Practice Deployment ==="

# System optimizations
sudo sysctl -w fs.file-max=65536 2>/dev/null || true
sudo sysctl -w vm.max_map_count=262144 2>/dev/null || true

echo "Building services..."
docker compose build --parallel

echo "Starting infrastructure..."
docker compose up -d postgres redis

echo "Waiting for databases..."
sleep 5

echo "Starting services..."
docker compose up -d order-service payment-service api-gateway

echo "Starting monitoring..."
docker compose up -d prometheus loki grafana postgres-exporter redis-exporter

echo "Starting chaos engine..."
docker compose up -d chaos-engine

echo ""
echo "=== Deployment Complete ==="
IP=$(curl -s ifconfig.me 2>/dev/null || echo "localhost")
echo "Grafana:    http://$IP:3000 (admin/admin)"
echo "Prometheus: http://$IP:9090"
echo "API:        http://$IP:8080"
echo ""
echo "Useful commands:"
echo "  View logs:    docker compose logs -f [service]"
echo "  Stop all:     docker compose down"
echo "  View stats:   docker stats"
EOF

chmod +x deploy.sh

echo "=== Project created in $PROJECT_NAME ==="
echo "Run: cd $PROJECT_NAME && ./deploy.sh"
