const { Storage } = require('@google-cloud/storage');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const { v4: uuidv4 } = require('uuid');

const upload = multer({
	storage: multer.memoryStorage(),
	limits: { fileSize: 5 * 1024 * 1024 },
	fileFilter: (req, file, cb) => {
		const allowed = ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/svg+xml'];
		cb(null, allowed.includes(file.mimetype));
	},
});

let storage = null;
let bucket = null;
let gcsPublicUrl = null;
let bucketName = null;
let useGCS = false;

function initStorage() {
	try {
		const projectId = process.env.GCS_PROJECT_ID;
		bucketName = process.env.GCS_BUCKET;
		const gcsEndpoint = process.env.GCS_ENDPOINT;
		gcsPublicUrl = process.env.GCS_PUBLIC_URL || gcsEndpoint;

		if (!projectId || !bucketName || projectId === 'your-project-id' || bucketName === '') {
			console.log('[Storage] GCS not configured - using local storage');
			useGCS = false;
			return false;
		}

		// Configure for emulator
		const storageConfig = { projectId };

		if (gcsEndpoint) {
			// For fake-gcs-server, we need to set apiEndpoint explicitly
			storageConfig.apiEndpoint = gcsEndpoint;
			// Don't use STORAGE_EMULATOR_HOST - it causes issues
			delete process.env.STORAGE_EMULATOR_HOST;
			console.log('[Storage] Using GCS emulator at:', gcsEndpoint);
		}

		storage = new Storage(storageConfig);
		bucket = storage.bucket(bucketName);

		// Create bucket asynchronously
		if (gcsEndpoint) {
			bucket.create()
				.then(() => console.log('[Storage] Created bucket:', bucketName))
				.catch(() => console.log('[Storage] Bucket exists:', bucketName));
		}

		console.log('[Storage] GCS bucket:', bucketName);
		useGCS = true;
		return true;
	} catch (error) {
		console.log('[Storage] GCS init failed:', error.message);
		useGCS = false;
		return false;
	}
}

async function uploadToGCS(file, folder = 'markets') {
	const filename = `${folder}/${uuidv4()}${path.extname(file.originalname)}`;
	const blob = bucket.file(filename);

	await blob.save(file.buffer, {
		contentType: file.mimetype,
		metadata: { cacheControl: 'public, max-age=31536000' },
	});

	try {
		await blob.makePublic();
	} catch (e) {
		// Emulator may not support makePublic
	}

	// Return appropriate URL based on environment
	if (gcsPublicUrl) {
		return `${gcsPublicUrl}/${bucketName}/${filename}`;
	}
	return `https://storage.googleapis.com/${bucketName}/${filename}`;
}

async function uploadToLocal(file, folder = 'markets') {
	// Use /tmp on App Engine (read-only filesystem except /tmp)
	const baseDir = process.env.GAE_APPLICATION ? '/tmp' : path.join(__dirname, '../../uploads');
	const uploadDir = path.join(baseDir, folder);

	try {
		if (!fs.existsSync(uploadDir)) {
			fs.mkdirSync(uploadDir, { recursive: true });
		}
	} catch (e) {
		console.log('[Storage] Could not create upload dir:', e.message);
		return null; // Skip image upload if directory can't be created
	}

	const filename = `${uuidv4()}${path.extname(file.originalname)}`;
	const filepath = path.join(uploadDir, filename);
	fs.writeFileSync(filepath, file.buffer);

	return `/uploads/${folder}/${filename}`;
}

async function uploadImage(file, folder = 'markets') {
	if (useGCS && bucket) {
		return uploadToGCS(file, folder);
	}
	return uploadToLocal(file, folder);
}

module.exports = { upload, initStorage, uploadImage };
