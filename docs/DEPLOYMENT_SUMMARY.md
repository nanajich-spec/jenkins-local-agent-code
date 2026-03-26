# Catool Deployment - Complete Configuration Summary

**Date:** March 10, 2026  
**Machine IP:** 132.186.17.22  
**Status:** ✅ Fully Operational

---

## 🎯 Changes Made

### 1. Backend API Updates
- **File:** `catool-backend-api/app.py`
- **Changes:** Configured CORS to allow specific frontend origins
- **CORS Settings:**
  - Allowed Origins: 
    - `http://132.186.17.22`
    - `http://132.186.17.22:30080`
    - `http://132.186.17.22:31286`
    - `http://132.186.17.22:30500`
  - Allowed Methods: `GET, POST, PUT, DELETE, OPTIONS`
  - Allowed Headers: `Content-Type, Authorization`
  - Credentials Support: `true`
- **Image:** `132.186.17.22:5000/catool-backend-api:1.0.1`

### 2. Frontend UI Configuration
- **File:** `cat-deployments/catool-ui/catool-ui-config.yml`
- **Changes:**
  - ❌ Removed: `baseUrl: 'https://cat.advantest.com/'`
  - ✅ Added: `baseUrl: 'http://132.186.17.22:31286/'`
  - ✅ Added: `apiUrl: 'http://132.186.17.22:30600/api/'`
  - ❌ Removed: `socket_io_url: 'https://cat.advantest.com'`
  - ✅ Added: `socket_io_url: 'http://132.186.17.22:31472'`

### 3. Namespace Service Configuration
- **File:** `cat-deployments/catool-ns/catool-ns-config.yml`
- **Changes:**
  - ❌ Removed: `catool_url: "https://cat.advantest.com/"`
  - ✅ Added: `catool_url: "http://132.186.17.22:31286/"`
  - ✅ Added: `api_url: "http://132.186.17.22:30600/api/"`

### 4. Deployment Updates
- **File:** `cat-deployments/catool-backend/catool-backend-deployment.yml`
- **Changes:**
  - Updated image to version 1.0.1
  - Set `imagePullPolicy: IfNotPresent`
- **Result:** All pods restarted with new configurations

---

## 🌐 Access Points

### Primary Entry Points
| Service | URL | Description |
|---------|-----|-------------|
| **Catool UI** | http://132.186.17.22:30080 | Main frontend interface |
| **Swagger Docs** | http://132.186.17.22:30600/docs | API documentation |
| **Backend API** | http://132.186.17.22:30600/api/ | REST API endpoints |
| **Ingress** | http://132.186.17.22:31286/ | Unified access point |

### API Endpoints

#### Authentication
- **Login:** `POST http://132.186.17.22:30600/api/auth/login`
  ```json
  {
    "username": "admin",
    "password": "password"
  }
  ```
  **Response:**
  ```json
  {
    "token": "sample-jwt-token",
    "expires_in": 3600,
    "user": {
      "id": 1,
      "username": "demo",
      "role": "admin"
    }
  }
  ```

- **Logout:** `POST http://132.186.17.22:30600/api/auth/logout`

#### User Management
- **List Users:** `GET http://132.186.17.22:30600/api/users/`
- **Get User:** `GET http://132.186.17.22:30600/api/users/{id}`
- **Create User:** `POST http://132.186.17.22:30600/api/users/`
- **Delete User:** `DELETE http://132.186.17.22:30600/api/users/{id}`

#### Tester Management
- **List Testers:** `GET http://132.186.17.22:30600/api/testers/`
- **Get Tester:** `GET http://132.186.17.22:30600/api/testers/{id}`
- **Tester Status:** `GET http://132.186.17.22:30600/api/testers/{id}/status`

#### System Endpoints
- **Health Check:** `GET http://132.186.17.22:30600/health`
- **Version Info:** `GET http://132.186.17.22:30600/version`
- **Catool Status:** `GET http://132.186.17.22:30600/api/catool/status`

### Additional Services
| Service | URL | Description |
|---------|-----|-------------|
| WebSocket | http://132.186.17.22:31472 | Real-time communication |
| Docker Registry | http://132.186.17.22:5000 | Container image registry |
| Registry Web UI | http://132.186.17.22:8080 | Browse registry images |
| Catool Frontend | http://132.186.17.22:30500 | Alternative frontend |

---

## 📦 Deployment Status

### Running Pods
```
NAMESPACE          DEPLOYMENT                    REPLICAS   STATUS
catool-backend     catool-backend-api            2/2        Running
catool-ui          catool-ui-deployment          1/1        Running
catool-ns          catool-ns-deployment          1/1        Running
catool-ns          catool-ns-ws-deployment       1/1        Running
catool-ns          catool-ns-db-deployment       1/1        Running
catool             catool-deployment             1/1        Running
catool             catool-worker-deployment      2/2        Running
catool             catool-postgres-deployment    1/1        Running
catool             catool-mq-deployment          1/1        Running
ingress-nginx      ingress-nginx-controller      1/1        Running
```

### Images in Registry
```
132.186.17.22:5000/catool-backend-api:1.0.1
132.186.17.22:5000/catool-backend-api:1.0.0
132.186.17.22:5000/catool-ui:1-0-0-beta-hotfix_2
132.186.17.22:5000/catool-ns
132.186.17.22:5000/catool
132.186.17.22:5000/postgres
132.186.17.22:5000/rabbitmq
```

---

## ✅ Verification Tests

### Test Authentication
```bash
curl -X POST http://132.186.17.22:30600/api/auth/login \
  -H "Content-Type: application/json" \
  -H "Origin: http://132.186.17.22:30080" \
  -d '{"username": "admin", "password": "password"}'
```

### Test CORS Headers
```bash
curl -I -X OPTIONS http://132.186.17.22:30600/api/users/ \
  -H "Origin: http://132.186.17.22:30080" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: Content-Type,Authorization"
```

### Expected CORS Response Headers
```
Access-Control-Allow-Origin: http://132.186.17.22:30080
Access-Control-Allow-Credentials: true
Access-Control-Allow-Headers: Authorization, Content-Type
Access-Control-Allow-Methods: DELETE, GET, OPTIONS, POST, PUT
```

### Test Health Check
```bash
curl http://132.186.17.22:30600/health
```

### Access Swagger UI
Open in browser: http://132.186.17.22:30600/docs

---

## 🔐 Security Notes

1. **Authentication:** Sample JWT implementation - replace with production auth system
2. **CORS:** Configured for specific origins only - not open to all domains
3. **Credentials:** Supports credentials (cookies, authorization headers)
4. **HTTP Only:** Currently using HTTP - consider HTTPS for production
5. **Database Password:** Hardcoded in configs - use Kubernetes secrets in production

---

## 🚀 Quick Start

### Access the Application
1. **Open Frontend:** http://132.186.17.22:30080
2. **View API Docs:** http://132.186.17.22:30600/docs
3. **Test Authentication:** Use Swagger UI to try login endpoint

### Make API Calls
```javascript
// Example: Login from frontend
fetch('http://132.186.17.22:30600/api/auth/login', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
  },
  credentials: 'include',
  body: JSON.stringify({
    username: 'admin',
    password: 'password'
  })
})
.then(response => response.json())
.then(data => console.log(data));
```

---

## 📝 Configuration Files Modified

1. `/root/Downloads/catool-backend-api/app.py` - CORS configuration
2. `/root/Downloads/cat-deployments/catool-ui/catool-ui-config.yml` - Frontend URLs
3. `/root/Downloads/cat-deployments/catool-ns/catool-ns-config.yml` - Namespace URLs
4. `/root/Downloads/cat-deployments/catool-backend/catool-backend-deployment.yml` - Image version

---

## 🎯 Key Achievements

✅ **Zero Advantest Dependencies:** All references to `cat.advantest.com` removed  
✅ **Local IP Configuration:** Everything uses `132.186.17.22`  
✅ **CORS Properly Configured:** Frontend can authenticate with backend  
✅ **Swagger Documentation:** Full API documentation available  
✅ **All Services Running:** 10 deployments operational  
✅ **Health Checks Passing:** All endpoints responding correctly  

---

## 📞 Support Information

**Deployment Date:** March 10, 2026  
**Docker Registry:** 132.186.17.22:5000  
**Kubernetes Version:** v1.29.15  
**Backend API Version:** 1.0.1  
**Frontend Version:** 0.4.2  

---

*This deployment is fully self-contained and does not require any external Advantest services.*
