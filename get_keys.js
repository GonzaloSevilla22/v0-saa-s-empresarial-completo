const { execSync } = require('child_process');
try {
    const output = execSync('npx supabase status -o json', { encoding: 'utf8' });
    const status = JSON.parse(output);
    console.log('ANON_KEY:', status.ANON_KEY);
    console.log('SERVICE_ROLE_KEY:', status.SERVICE_ROLE_KEY);
    console.log('API_URL:', status.API_URL);
} catch (e) {
    console.error('Error fetching status:', e.message);
    // Fallback to non-json if json fails
    try {
        const outputRaw = execSync('npx supabase status', { encoding: 'utf8' });
        console.log('RAW_STATUS:\n', outputRaw);
    } catch (e2) {
        console.error('Fallback failed:', e2.message);
    }
}
