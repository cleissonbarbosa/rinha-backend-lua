const express = require('express');
const app = express();

app.use(express.json());

// Simulate different fee rates and stability
const isDefault = process.argv[2] === 'default';
const port = isDefault ? 8080 : 8081;
const processorName = isDefault ? 'Default' : 'Fallback';
const feeRate = isDefault ? 0.05 : 0.10;

// Track stats
let totalRequests = 0;
let totalAmount = 0;
let isInFailure = false;
let minProcessingTime = isDefault ? 50 : 100;

// Simulate random failures for testing
const failureRate = isDefault ? 0.1 : 0.05; // Default processor fails more often

// POST /payments
app.post('/payments', (req, res) => {
    const { correlationId, amount, requestedAt } = req.body;
    
    // Simulate processing time
    const processingTime = Math.random() * 100 + minProcessingTime;
    
    setTimeout(() => {
        // Simulate random failures
        if (Math.random() < failureRate) {
            console.log(`${processorName} processor: Payment failed for ${correlationId}`);
            return res.status(500).json({ error: 'Payment processing failed' });
        }
        
        totalRequests++;
        totalAmount += amount;
        
        console.log(`${processorName} processor: Payment processed - ${correlationId} - $${amount}`);
        res.json({ message: 'payment processed successfully' });
    }, Math.min(processingTime, 50)); // Cap delay for responsiveness
});

// GET /payments/service-health
app.get('/payments/service-health', (req, res) => {
    // Simulate health changes
    if (Math.random() < 0.05) {
        isInFailure = !isInFailure;
        minProcessingTime = isInFailure ? 1000 : (isDefault ? 50 : 100);
    }
    
    res.json({
        isInFailure,
        minProcessingTimeMs: minProcessingTime
    });
});

// GET /payments-summary for debugging
app.get('/payments-summary', (req, res) => {
    res.json({
        processor: processorName,
        totalRequests,
        totalAmount,
        feeRate,
        isInFailure,
        minProcessingTime
    });
});

app.listen(port, () => {
    console.log(`${processorName} Payment Processor running on port ${port}`);
    console.log(`Fee rate: ${(feeRate * 100)}%`);
});