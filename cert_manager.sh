#!/bin/bash

# Color definitions for clean output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

clear
echo -e "${PURPLE}==================================================${NC}"
echo -e "${CYAN}    ACME.sh Automated SSL Certificate Manager     ${NC}"
echo -e "${PURPLE}==================================================${NC}"

# 1. Dependency Check
echo -e "\n${BLUE}[1/4] Checking system dependencies...${NC}"
for cmd in curl socat cron; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${YELLOW}Tools $cmd not found. Installing...${NC}"
        apt-get update -y && apt-get install $cmd -y
    fi
done

# Install acme.sh core if missing
if [ ! -d "$HOME/.acme.sh" ]; then
    echo -e "${YELLOW}Installing acme.sh core engine...${NC}"
    curl https://get.acme.sh | sh -s email=my-ssl@le-fallback.com
    source ~/.bashrc
fi

# Set default CA to Let's Encrypt
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 2. Main Menu Options
echo -e "\n${CYAN}Select Action:${NC}"
echo -e "${GREEN}1)${NC} Issue / Renew Certificate (Smart Auto-Detect)"
echo -e "${GREEN}2)${NC} Check Existing Certificates Status"
read -p "$(echo -e ${YELLOW}"Choose action [1 or 2]: "${NC})" ACTION

# Handle Certificate Status Checking
if [ "$ACTION" == "2" ]; then
    echo -e "\n${BLUE}[3/4] Fetching Active Certificates Status...${NC}"
    echo -e "${PURPLE}--------------------------------------------------${NC}"
    ~/.acme.sh/acme.sh --list
    echo -e "${PURPLE}--------------------------------------------------${NC}"
    exit 0
fi

# 3. Domain Configuration
echo -e "\n${BLUE}[2/4] Domain Configuration...${NC}"
read -p "$(echo -e ${YELLOW}"Enter your domain name (e.g., sub.domain.com): "${NC})" DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Error: Domain name cannot be empty.${NC}"
    exit 1
fi

TARGET_DIR="/root/${DOMAIN}/certs"

echo -e "\n${CYAN}Select Validation Method:${NC}"
echo -e "${GREEN}1)${NC} Standalone Mode (Port 80) - Requires domain pointing to this VPS"
echo -e "${GREEN}2)${NC} Manual DNS Mode (TXT Record) - Best for Cloudflare / hidden origins"
read -p "$(echo -e ${YELLOW}"Choose method [1 or 2]: "${NC})" METHOD

# 4. Execution Phase
echo -e "\n${BLUE}[3/4] Processing Request...${NC}"

# تابع کمکی برای بررسی کپچر کردن خروجی و تشخیص نیاز به force
run_acme() {
    local force_mode=$1
    local log_file="/tmp/acme_run.log"
    
    if [ "$METHOD" == "1" ]; then
        echo -e "${CYAN}Standalone mode selected. Opening port 80...${NC}"
        if command -v ufw &> /dev/null; then ufw allow 80/tcp && ufw reload; fi
        if command -v iptables &> /dev/null; then iptables -A INPUT -p tcp --dport 80 -j ACCEPT; fi
        
        echo -e "${YELLOW}Requesting SSL via internal standalone webserver...${NC}"
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --insecure $force_mode 2>&1 | tee $log_file
    else
        echo -e "${CYAN}DNS Manual mode selected. Generating TXT record...${NC}"
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns --yes-I-know-dns-manual-mode-enough-go-to-auto-issue $force_mode 2>&1 | tee $log_file
        
        # اگر در حالت اول به فورس نیاز نداشت و تمدید دستی بود، باید تاییدیه رکورد را بگیریم
        if ! grep -q "Add '--force' to force renewal" $log_file; then
            echo -e "\n${PURPLE}==================================================${NC}"
            echo -e "${RED}⚠️  CRITICAL ACTION REQUIRED:${NC}"
            echo -e "${YELLOW}1. Log in to your DNS Provider (e.g., Cloudflare).${NC}"
            echo -e "${YELLOW}2. Add a new ${GREEN}TXT${YELLOW} record.${NC}"
            echo -e "${YELLOW}3. Type/Name:${NC} ${CYAN}_acme-challenge.${DOMAIN}${NC}"
            echo -e "${YELLOW}4. Value:${NC} [Use the green/red string generated above]"
            echo -e "${PURPLE}==================================================${NC}"
            read -p "$(echo -e ${GREEN}"After adding the TXT record, wait 60s and press [Enter] to renew/verify... "${NC})"
            ~/.acme.sh/acme.sh --renew -d "$DOMAIN" --yes-I-know-dns-manual-mode-enough-go-to-auto-issue $force_mode 2>&1 | tee $log_file
        fi
    fi
    
    # بررسی هوشمند متن خروجی برای تشخیص نیاز به --force
    if grep -q "Add '--force' to force renewal" $log_file; then
        echo -e "\n${YELLOW}ℹ Deteted active certificate for $DOMAIN. It's not expired yet.${NC}"
        read -p "$(echo -e ${PURPLE}"Do you want to force renew/overwrite it? [y/N]: "${NC})" CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Re-running with --force flag...${NC}"
            run_acme "--force" # فراخوانی بازگشتی با پرچم فورس
        else
            echo -e "${RED}Skipped force renewal by user.${NC}"
            return 1
        fi
    fi
}

# اجرای تابع هوشمند
run_acme ""
ACME_EXIT_CODE=${PIPESTATUS[0]}

# 5. Export and Summary
if [ $ACME_EXIT_CODE -eq 0 ] && [ -f "$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key" -o -f "$HOME/.acme.sh/${DOMAIN}/${DOMAIN}.key" ]; then
    echo -e "\n${BLUE}[4/4] Exporting certificates to target directory...${NC}"
    
    mkdir -p "$TARGET_DIR"
    
    # Installing certs to structural paths
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$TARGET_DIR/privkey.pem" \
        --fullchain-file "$TARGET_DIR/fullchain.pem" > /dev/null
        
    echo -e "\n${GREEN}✔ Certificate successfully issued and saved!${NC}"
    echo -e "${PURPLE}--------------------------------------------------${NC}"
    echo -e "${CYAN}📂 Target Directory:${NC} ${TARGET_DIR}/"
    echo -e "${GREEN}🔑 Private Key:${NC}      $TARGET_DIR/privkey.pem"
    echo -e "${GREEN}📜 Fullchain Cert:${NC}   $TARGET_DIR/fullchain.pem"
    echo -e "${PURPLE}--------------------------------------------------${NC}"
else
    echo -e "\n${RED}❌ Process finished without generating new files.${NC}"
fi
