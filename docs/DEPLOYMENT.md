# Deployment Configuration Guide

This guide explains how to configure secrets for each deployment option in the unified CI/CD workflow. All deployments are **optional** and modular - simply add the required secrets to your repository to enable a deployment target.

## Table of Contents

- [NPM Registry](#npm-registry)
- [Docker Hub](#docker-hub)
- [Cloudflare Pages](#cloudflare-pages)
- [Railway](#railway)
- [Vercel](#vercel)
- [Build Environment Variables](#build-environment-variables)

---

## NPM Registry

**Project Type:** `library`

Deploy your packages to the NPM registry (npmjs.com).

### Required Secrets

| Secret Name | Description |
|------------|-------------|
| `NPM_TOKEN` | NPM authentication token for publishing packages |

### How to Get NPM_TOKEN

1. **Log in to NPM:**
   ```bash
   npm login
   ```

2. **Generate an Access Token:**
   - Go to [npmjs.com](https://www.npmjs.com/)
   - Click your profile picture → **Access Tokens**
   - Click **Generate New Token**
   - Select **Automation** token type (for CI/CD)
   - Copy the generated token

3. **Add to GitHub Secrets:**
   - Go to your repository on GitHub
   - Navigate to **Settings** → **Secrets and variables** → **Actions**
   - Click **New repository secret**
   - Name: `NPM_TOKEN`
   - Value: Paste your NPM token
   - Click **Add secret**

### Additional Configuration

- Set `npm-access` input to `public` or `restricted` in your workflow file
- For scoped packages (e.g., `@sudobility/package`), use `restricted` unless you want them public

---

## Docker Hub

**Project Type:** `docker-app`, `webapp`

Build and push multi-architecture Docker images (arm64, amd64) to Docker Hub.

### Required Secrets

| Secret Name | Description |
|------------|-------------|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not your password) |

### How to Get Docker Hub Secrets

1. **Create a Docker Hub Account:**
   - Sign up at [hub.docker.com](https://hub.docker.com/)

2. **Generate an Access Token:**
   - Log in to Docker Hub
   - Click your username → **Account Settings**
   - Navigate to **Security** → **Access Tokens**
   - Click **New Access Token**
   - Give it a description (e.g., "GitHub Actions CI/CD")
   - Select permissions (recommend **Read, Write, Delete**)
   - Click **Generate**
   - Copy the token (you won't see it again!)

3. **Add to GitHub Secrets:**
   - `DOCKERHUB_USERNAME`: Your Docker Hub username
   - `DOCKERHUB_TOKEN`: The access token you just generated

### Additional Configuration

- You can customize the Docker image name using the `docker-image-name` input
- If not specified, it defaults to your repository name
- Images are tagged as `latest` and with the version from package.json

---

## Cloudflare Pages

**Project Type:** `webapp`

Deploy static sites and frontend applications to Cloudflare Pages.

### Required Secrets

| Secret Name | Description |
|------------|-------------|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token with Pages permissions |
| `CLOUDFLARE_ACCOUNT_ID` | Your Cloudflare account ID |

### How to Get Cloudflare Secrets

1. **Get Your Account ID:**
   - Log in to [dash.cloudflare.com](https://dash.cloudflare.com/)
   - Select any website or go to **Pages**
   - Your **Account ID** is visible in the right sidebar (or in the URL)
   - Copy this ID

2. **Create an API Token:**
   - Go to [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
   - Click **Create Token**
   - Use the **Edit Cloudflare Workers** template (or create custom)
   - **Permissions needed:**
     - Account → Cloudflare Pages → Edit
   - Click **Continue to summary**
   - Click **Create Token**
   - Copy the token (you won't see it again!)

3. **Add to GitHub Secrets:**
   - `CLOUDFLARE_API_TOKEN`: The API token you just created
   - `CLOUDFLARE_ACCOUNT_ID`: Your account ID

### Additional Configuration

- You can customize the Cloudflare project name using the `cloudflare-project-name` input
- If not specified, it defaults to your repository name
- The workflow deploys the `dist` directory by default
- Make sure your build script outputs to `dist`

### Create Cloudflare Pages Project (First Time)

Before your first deployment, create the project in Cloudflare:
1. Go to **Workers & Pages** → **Pages**
2. Click **Create a project**
3. Choose **Direct Upload** (not Git integration)
4. Name your project (should match your repository name or `cloudflare-project-name`)
5. The CI/CD will handle all subsequent deployments

---

## Railway

**Project Type:** `webapp`, `docker-app`

Deploy applications to Railway's container platform.

### Required Secrets

| Secret Name | Description |
|------------|-------------|
| `RAILWAY_TOKEN` | Railway API token for deployments |
| `RAILWAY_SERVICE` | Railway service ID or name to deploy to |

### How to Get Railway Secrets

1. **Create a Railway Account:**
   - Sign up at [railway.app](https://railway.app/)

2. **Create a Project and Service:**
   - Click **New Project** → **Empty Project**
   - Give your project a name
   - Click on the project to open it
   - Note: Railway will create a service automatically, or you can create one manually

3. **Get Service ID:**
   - In your Railway project dashboard
   - Click on your service
   - Go to **Settings**
   - Copy the **Service ID** (looks like: `a1b2c3d4-5678-90ab-cdef-1234567890ab`)

4. **Generate API Token:**
   - Click your profile picture → **Account Settings**
   - Navigate to **Tokens** tab
   - Click **Create Token**
   - Give it a name (e.g., "GitHub Actions")
   - Copy the token (you won't see it again!)

5. **Add to GitHub Secrets:**
   - `RAILWAY_TOKEN`: The API token you just created
   - `RAILWAY_SERVICE`: The service ID from step 3

### Additional Notes

- Railway automatically detects Dockerfiles and builds accordingly
- You can also deploy Node.js apps without Docker
- The workflow uses `railway up --detach` for deployment
- Monitor deployments in your Railway dashboard

---

## Vercel

**Project Type:** `webapp`

Deploy frontend applications and serverless functions to Vercel.

### Required Secrets

| Secret Name | Description |
|------------|-------------|
| `VERCEL_TOKEN` | Vercel authentication token |
| `VERCEL_ORG_ID` | Your Vercel organization/team ID |
| `VERCEL_PROJECT_ID` | The specific project ID in Vercel |

### How to Get Vercel Secrets

1. **Create a Vercel Account:**
   - Sign up at [vercel.com](https://vercel.com/)

2. **Install Vercel CLI (locally):**
   ```bash
   npm install -g vercel
   ```

3. **Link Your Project:**
   ```bash
   cd your-project-directory
   vercel link
   ```
   - Follow the prompts to link to an existing project or create a new one
   - This creates a `.vercel/project.json` file

4. **Get Organization and Project IDs:**
   ```bash
   cat .vercel/project.json
   ```
   - You'll see:
     ```json
     {
       "orgId": "team_xxxxxxxxxxxx",
       "projectId": "prj_xxxxxxxxxxxx"
     }
     ```
   - Copy these IDs

5. **Generate an Access Token:**
   - Go to [vercel.com/account/tokens](https://vercel.com/account/tokens)
   - Click **Create**
   - Give it a name (e.g., "GitHub Actions CI/CD")
   - Select scope: **Full Account** or specific team
   - Set expiration (recommend: No Expiration for CI/CD)
   - Click **Create Token**
   - Copy the token (you won't see it again!)

6. **Add to GitHub Secrets:**
   - `VERCEL_TOKEN`: The access token you just created
   - `VERCEL_ORG_ID`: The `orgId` from `.vercel/project.json`
   - `VERCEL_PROJECT_ID`: The `projectId` from `.vercel/project.json`

### Additional Notes

- The workflow deploys to **production** with `vercel deploy --prod`
- Vercel automatically detects your framework (Next.js, Vite, etc.)
- The deployment URL is captured and displayed in the workflow logs
- You don't need to commit `.vercel/` directory to Git (it's for local setup only)

---

## Build Environment Variables

The workflow **automatically detects and passes** build-time environment variables to the build process based on common naming conventions.

### Supported Prefixes

The following secret prefixes are automatically passed to builds:

| Prefix | Framework | Example |
|--------|-----------|---------|
| `VITE_*` | Vite | `VITE_REVENUECAT_API_KEY`, `VITE_API_URL` |
| `REACT_APP_*` | Create React App | `REACT_APP_API_KEY`, `REACT_APP_ENV` |
| `NEXT_PUBLIC_*` | Next.js | `NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_GA_ID` |
| `BUILD_*` | Generic | `BUILD_VERSION`, `BUILD_TIMESTAMP` |

### How to Add Build Environment Variables

1. **Add secret to repository** (Settings → Secrets and variables → Actions)
2. **Name it with the correct prefix** (e.g., `VITE_API_KEY`)
3. **No workflow changes needed** - it's automatically available during build!

### Example Usage

In your code, access them as usual:
   ```javascript
   // Vite
   const apiKey = import.meta.env.VITE_REVENUECAT_API_KEY

   // Create React App
   const apiKey = process.env.REACT_APP_API_KEY

   // Next.js
   const apiUrl = process.env.NEXT_PUBLIC_API_URL
   ```

### Using Non-Standard Prefixes

If you need environment variables with different prefixes (not `VITE_`, `REACT_APP_`, `NEXT_PUBLIC_`, or `BUILD_`), you have two options:

**Option 1: Rename to use a supported prefix** (Recommended)
```
MY_API_KEY → VITE_API_KEY (then access as import.meta.env.VITE_API_KEY)
```

**Option 2: Use the `secrets: inherit` pattern** (Already the default)
All secrets are already passed to the workflow via `secrets: inherit`. The workflow filters to supported prefixes for security. If you need all secrets available during build, you would need to modify the unified workflow's filter pattern.

---

## Testing Your Configuration

After adding secrets:

1. **Verify secrets are set:**
   - Go to **Settings** → **Secrets and variables** → **Actions**
   - Confirm all required secrets for your deployment target(s) are listed

2. **Trigger a deployment:**
   - Push to your main branch
   - The workflow will automatically detect configured secrets
   - Check the Actions tab to see which deployments are running

3. **Monitor the workflow:**
   - In the Actions tab, click on the running workflow
   - Each deployment job will show whether secrets are configured
   - If secrets are missing, you'll see: "ℹ️  [Service] secrets not configured, skipping deployment"

---

## Security Best Practices

1. **Never commit secrets** to your repository
2. **Use repository secrets** instead of hardcoding values
3. **Rotate tokens regularly** (especially if exposed)
4. **Use minimal permissions** for tokens (only what's needed)
5. **Audit access** periodically through provider dashboards
6. **Delete unused tokens** to reduce attack surface

---

## Troubleshooting

### Deployment job runs but skips deployment

**Cause:** Required secrets are not configured

**Solution:**
- Check the workflow logs for messages like "secrets not configured"
- Verify you've added all required secrets for that deployment target
- Ensure secret names exactly match (case-sensitive)

### NPM publish fails with 403

**Cause:** Insufficient permissions or wrong token type

**Solution:**
- Regenerate token using **Automation** type (not Classic)
- Verify token has publish permissions
- Check if package name conflicts with existing package

### Docker push fails with authentication error

**Cause:** Invalid credentials or token expired

**Solution:**
- Verify `DOCKERHUB_USERNAME` is correct (case-sensitive)
- Regenerate Docker Hub access token
- Ensure token has write permissions

### Cloudflare deployment fails with "project not found"

**Cause:** Project doesn't exist in Cloudflare Pages

**Solution:**
- Create the project in Cloudflare Pages dashboard first
- Use Direct Upload method (not Git integration)
- Ensure project name matches your configuration

### Railway deployment fails with "service not found"

**Cause:** Invalid service ID or token

**Solution:**
- Double-check the service ID from Railway dashboard
- Ensure the service exists in your Railway project
- Verify token has access to the correct project

### Vercel deployment fails with "project not found"

**Cause:** Incorrect project ID or organization ID

**Solution:**
- Re-run `vercel link` locally to get correct IDs
- Verify `VERCEL_ORG_ID` and `VERCEL_PROJECT_ID` match `.vercel/project.json`
- Ensure token has access to the organization/team

---

## Need Help?

- Check the workflow logs in the Actions tab for detailed error messages
- Refer to provider documentation:
  - [NPM Tokens](https://docs.npmjs.com/about-access-tokens)
  - [Docker Hub Access Tokens](https://docs.docker.com/docker-hub/access-tokens/)
  - [Cloudflare API Tokens](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
  - [Railway CLI](https://docs.railway.app/develop/cli)
  - [Vercel CLI](https://vercel.com/docs/cli)
